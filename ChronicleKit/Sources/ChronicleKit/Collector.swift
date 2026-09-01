import Foundation

/// The shared collection pass used by the GUI collector loop and every CLI
/// `show`/`session` command.
public enum Collector {
    /// Resolves the session the CLI should operate on, creating or resuming
    /// one from the current Tuple call when needed.
    public static func ensureCurrentSession(
        store: ChronicleStore, tuple: any TupleCalling
    ) throws -> SessionRecord {
        if let session = try store.currentSession() {
            // Existing active/finalizing session writes remain available when
            // Tuple is between calls or its CLI is temporarily unavailable.
            if let callId = try? tuple.currentCall(), callId != session.id {
                return try store.createOrResumeSession(callId: callId)
            }
            return session
        }
        guard let callId = try tuple.currentCall() else {
            throw ChronicleError("no active Chronicle session; join a Tuple call and open Chronicle first")
        }
        return try store.createOrResumeSession(callId: callId)
    }

    /// `startSessions` controls whether a detected Tuple call may create or
    /// resume a session. The CLI keeps the default — running the skill is an
    /// explicit act — while the GUI collector passes false and only records
    /// the available call, so sessions start from the app's Start Session
    /// button rather than merely because Chronicle was open during a call.
    public static func collectOnce(
        store: ChronicleStore, tuple: any TupleCalling, timeout: String,
        startSessions: Bool = true
    ) throws {
        let currentCall: Result<String?, Error>
        do {
            currentCall = .success(try tuple.currentCall())
        } catch {
            currentCall = .failure(error)
        }
        var session = try store.currentSession()
        if case .success = currentCall {
            try store.setTupleDiscoveryError(nil)
        }
        switch currentCall {
        case .success(.some(let callId)):
            if session?.id != callId, startSessions {
                session = try store.createOrResumeSession(callId: callId)
            }
            if let active = session, active.state == .active {
                if active.id == callId {
                    try store.clearTupleCallMissing()
                    try store.touchSession(active.id)
                    try tuple.collect(store: store, session: active, timeout: timeout)
                } else {
                    // Tuple moved on to a different call. Keep draining the
                    // tracked call's cursor for its call_ended and run the
                    // missing-call grace timer, exactly as if no call existed.
                    try tuple.collect(store: store, session: active, timeout: timeout)
                    if try store.session(active.id).state == .active {
                        try store.recordTupleCallMissing(sessionId: active.id)
                    }
                }
            }
            try store.setAvailableTupleCall(try store.currentSession() == nil ? callId : nil)
        case .success(.none):
            try store.setAvailableTupleCall(nil)
            // A reader scoped to the stable call ID receives Tuple's explicit
            // call_ended status after the current-call endpoint becomes empty.
            if let active = session, active.state == .active {
                try tuple.collect(store: store, session: active, timeout: timeout)
                // Tuple does not always emit call_ended; infer the end once
                // "not in a call" has persisted past the grace period.
                if try store.session(active.id).state == .active {
                    try store.recordTupleCallMissing(sessionId: active.id)
                }
            }
        case .failure(let error):
            try? store.setAvailableTupleCall(nil)
            let message = (error as? ChronicleError)?.message ?? error.localizedDescription
            if let active = session {
                try store.setSourceState(
                    sessionId: active.id, source: SourceName.tuple, status: "error", detail: message)
            } else {
                try store.setTupleDiscoveryError(message)
                throw error
            }
        }
        if let active = session {
            try IDEIngestion.discover(store: store, session: active)
            try IDEIngestion.collect(store: store, session: active)
        }
    }
}
