import Foundation

/// Tail cursor persisted in `source_state.cursor_json` for the IDE plugin log.
struct IDECursor: Codable, Equatable {
    var path: String
    var offset: Int64
    var fileId: UInt64?
    var lastSequence: Int64
    var lastType: String?
    /// Set when the log failed closed on a bad record: the position just past
    /// it, so the user can explicitly resume without the plugin or app updating.
    var failedNext: IDESkipTarget? = nil
}

struct IDESkipTarget: Codable, Equatable {
    var offset: Int64
    var lastSequence: Int64
}

/// A per-record log failure: the valid prefix parsed before it, plus where
/// tailing would resume if the user chooses to skip the record.
struct IDELogFailure: Error {
    var message: String
    var events: [NormalizedEvent]
    var consumed: Int
    var nextSequence: Int64
}

struct ParsedIDEChunk {
    var events: [NormalizedEvent]
    var consumed: Int
    var lastSequence: Int64
    var lastType: String?
}

/// Reads the IDE plugin's published data per the wire contract. Never modifies
/// anything under the IDE root.
public enum IDEIngestion {
    // MARK: - Discovery

    public static func discover(store: ChronicleStore, session: SessionRecord) throws {
        guard let repo = session.repoPath else {
            try store.replaceIDECandidates(sessionId: session.id, candidates: [])
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "off",
                detail: "Attach a repository to discover Chronicle.")
            return
        }
        let registryURL = try store.ideRoot().appendingPathComponent("sessions.json")
        let raw: Data
        do {
            raw = try Data(contentsOf: registryURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
        {
            try store.replaceIDECandidates(sessionId: session.id, candidates: [])
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "off",
                detail: "Not detected")
            return
        } catch {
            let message = "cannot read Chronicle registry \(registryURL.path): \(error.localizedDescription)"
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "error", detail: message)
            throw ChronicleError(message)
        }
        let parsed: [IDESessionCandidate]
        do {
            parsed = try parseRegistry(raw)
        } catch {
            let message = "invalid Chronicle registry \(registryURL.path): \(messageText(error))"
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "error", detail: message)
            throw ChronicleError(message)
        }
        let candidates = matchCandidates(
            parsed, repo: repo,
            sessionStart: session.startedAt,
            sessionEnd: try store.sessionEnd(session.id))
        try store.replaceIDECandidates(sessionId: session.id, candidates: candidates)
        switch (candidates.count, try store.selectedIDECandidate(sessionId: session.id)) {
        case (0, _):
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "off",
                detail: "Not detected")
        case (1, _):
            try setCandidateHealth(store: store, sessionId: session.id, candidate: candidates[0])
        case (_, .some(let selected)):
            try setCandidateHealth(store: store, sessionId: session.id, candidate: selected)
        case (_, .none):
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "ambiguous",
                detail: "Multiple IDE sessions match this repository.")
        }
    }

    /// Used by the app's Settings pane to sanity-check an explicit IDE folder.
    public static func validateIDERoot(_ root: URL) throws {
        let registry = root.appendingPathComponent("sessions.json")
        let raw: Data
        do {
            raw = try Data(contentsOf: registry)
        } catch {
            throw ChronicleError(
                "cannot read Chronicle registry \(registry.path): \(error.localizedDescription)")
        }
        _ = try parseRegistry(raw)
    }

    // MARK: - Log tailing

    public static func collect(store: ChronicleStore, session: SessionRecord) throws {
        guard let candidate = try store.selectedIDECandidate(sessionId: session.id) else {
            return
        }
        let logURL = URL(fileURLWithPath: candidate.logPath)
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: logURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
        {
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "stopped",
                detail: "Chronicle log is not available.")
            return
        } catch {
            throw ChronicleError(
                "cannot read Chronicle log \(candidate.logPath): \(error.localizedDescription)")
        }
        defer { try? file.close() }
        var status = stat()
        guard fstat(file.fileDescriptor, &status) == 0 else {
            throw ChronicleError(
                "cannot inspect Chronicle log \(candidate.logPath): \(String(cString: strerror(errno)))")
        }
        let size = Int64(status.st_size)
        let fileId = UInt64(status.st_ino)
        let previousJson = try store.sourceState(sessionId: session.id, source: SourceName.chronicle)?
            .cursorJson
        let previous = previousJson.flatMap {
            try? JSONDecoder().decode(IDECursor.self, from: Data($0.utf8))
        }
        let cursor: IDECursor
        if let previous,
            previous.path == candidate.logPath,
            previous.offset <= size,
            previous.fileId == nil || previous.fileId == fileId
        {
            cursor = previous
        } else {
            cursor = IDECursor(
                path: candidate.logPath, offset: 0, fileId: fileId, lastSequence: 0, lastType: nil)
        }
        let bytes: Data
        do {
            try file.seek(toOffset: UInt64(cursor.offset))
            bytes = try file.readToEnd() ?? Data()
        } catch {
            throw ChronicleError(
                "cannot tail Chronicle log \(candidate.logPath): \(error.localizedDescription)")
        }
        let observedAt = ChronicleTimestamp.now()
        let chunk: ParsedIDEChunk
        do {
            chunk = try parseChunk(
                bytes, candidate: candidate,
                previousSequence: cursor.lastSequence, previousType: cursor.lastType,
                observedAt: observedAt)
        } catch let failure as IDELogFailure {
            // Fail closed: the cursor stays put. The valid records before the
            // bad one are committed now (stable IDs dedupe any replay), and
            // the position past the bad record is stored so the user can
            // choose to skip it from the error banner.
            try store.insertSourceEvents(sessionId: session.id, events: failure.events)
            var preserved = cursor
            preserved.failedNext = IDESkipTarget(
                offset: cursor.offset + Int64(failure.consumed),
                lastSequence: failure.nextSequence)
            let message = "Invalid Chronicle log \(candidate.logPath): \(failure.message)"
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "error",
                detail: message, cursorJson: encodeCursor(preserved))
            throw ChronicleError(message)
        } catch {
            let message = "Invalid Chronicle log \(candidate.logPath): \(messageText(error))"
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "error",
                detail: message, cursorJson: previousJson)
            throw ChronicleError(message)
        }
        if candidate.state == .completed, chunk.lastType != "session_ended" {
            let message =
                "Chronicle marks \(candidate.id) completed, but its log does not end with session_ended"
            try store.setSourceState(
                sessionId: session.id, source: SourceName.chronicle, status: "error",
                detail: message, cursorJson: previousJson)
            throw ChronicleError(message)
        }
        try store.insertSourceEvents(sessionId: session.id, events: chunk.events)
        let updated = IDECursor(
            path: candidate.logPath, offset: cursor.offset + Int64(chunk.consumed),
            fileId: fileId, lastSequence: chunk.lastSequence, lastType: chunk.lastType)
        try setCandidateHealth(
            store: store, sessionId: session.id, candidate: candidate,
            cursorJson: encodeCursor(updated))
    }

    /// The user's explicit escape from a fail-closed log: advance the cursor
    /// past the record the last collect pass failed on. The records before it
    /// were already committed at failure time; only the bad record is lost.
    public static func skipFailedRecord(store: ChronicleStore, sessionId: String) throws {
        guard
            let state = try store.sourceState(sessionId: sessionId, source: SourceName.chronicle),
            let json = state.cursorJson,
            let cursor = try? JSONDecoder().decode(IDECursor.self, from: Data(json.utf8)),
            let target = cursor.failedNext
        else {
            throw ChronicleError("no failed Chronicle record to skip")
        }
        let resumed = IDECursor(
            path: cursor.path, offset: target.offset, fileId: cursor.fileId,
            lastSequence: target.lastSequence, lastType: nil)
        try store.setSourceState(
            sessionId: sessionId, source: SourceName.chronicle, status: "waiting",
            detail: "Skipped an unreadable Chronicle record; resuming on the next pass.",
            cursorJson: encodeCursor(resumed))
    }

    private static func encodeCursor(_ cursor: IDECursor) throws -> String {
        do {
            return String(decoding: try ChronicleStore.encoder.encode(cursor), as: UTF8.self)
        } catch {
            throw ChronicleError("cannot encode Chronicle cursor: \(error.localizedDescription)")
        }
    }

    private static func setCandidateHealth(
        store: ChronicleStore, sessionId: String,
        candidate: IDESessionCandidate, cursorJson: String? = nil
    ) throws {
        let (status, detail): (String, String)
        switch candidate.state {
        case .active: (status, detail) = ("live", "Chronicle detected")
        case .completed: (status, detail) = ("ended", "Chronicle recording completed")
        case .interrupted: (status, detail) = ("stopped", "Chronicle recording was interrupted")
        }
        try store.setSourceState(
            sessionId: sessionId, source: SourceName.chronicle, status: status,
            detail: detail, cursorJson: cursorJson)
    }

    // MARK: - Registry parsing

    /// Unknown registry fields are tolerated so the plugin can evolve;
    /// everything present is still validated strictly.
    static func parseRegistry(_ raw: Data) throws -> [IDESessionCandidate] {
        let document: JSONValue
        do {
            document = try JSONDecoder().decode(JSONValue.self, from: raw)
        } catch {
            throw ChronicleError("sessions.json does not match schema 1: \(error.localizedDescription)")
        }
        guard let root = document.objectValue else {
            throw ChronicleError("sessions.json does not match schema 1: top level must be an object")
        }
        guard let schemaVersion = integer(root["schemaVersion"]) else {
            throw ChronicleError("sessions.json does not match schema 1: schemaVersion must be an integer")
        }
        guard schemaVersion == 1 else {
            throw ChronicleError("unsupported sessions.json schemaVersion \(schemaVersion)")
        }
        guard let updatedAt = root["updatedAt"]?.stringValue else {
            throw ChronicleError("sessions.json does not match schema 1: updatedAt must be a string")
        }
        try validateWireTimestamp(updatedAt, name: "updatedAt")
        guard let sessions = root["sessions"]?.arrayValue else {
            throw ChronicleError("sessions.json does not match schema 1: sessions must be an array")
        }
        var ids = Set<String>()
        var candidates: [IDESessionCandidate] = []
        candidates.reserveCapacity(sessions.count)
        for entry in sessions {
            guard let object = entry.objectValue else {
                throw ChronicleError("sessions.json does not match schema 1: session entries must be objects")
            }
            let id = try registryString(object, "id", label: "session id")
            try validateNonempty(id, name: "session id")
            guard ids.insert(id).inserted else {
                throw ChronicleError("duplicate Chronicle session id \(id)")
            }
            let stateText = try registryString(object, "state", label: "state")
            guard let state = IDESessionState(rawValue: stateText) else {
                throw ChronicleError("invalid Chronicle session state \(stateText)")
            }
            let logPath = try registryString(object, "logPath", label: "logPath")
            try validateAbsolutePath(logPath, name: "logPath")
            let projectRoot = try registryString(object, "projectRoot", label: "projectRoot")
            try validateAbsolutePath(projectRoot, name: "projectRoot")
            let projectName = try registryString(object, "projectName", label: "projectName")
            try validateNonempty(projectName, name: "projectName")
            let startedAt = try registryString(object, "startedAt", label: "startedAt")
            try validateWireTimestamp(startedAt, name: "startedAt")
            let lastEventAt = try registryString(object, "lastEventAt", label: "lastEventAt")
            try validateWireTimestamp(lastEventAt, name: "lastEventAt")
            let heartbeatAt = try registryString(object, "heartbeatAt", label: "heartbeatAt")
            try validateWireTimestamp(heartbeatAt, name: "heartbeatAt")
            var endedAt: String?
            switch object["endedAt"] {
            case .none, .some(.null):
                endedAt = nil
            case .some(.string(let value)):
                try validateWireTimestamp(value, name: "endedAt")
                endedAt = value
            default:
                throw ChronicleError("sessions.json does not match schema 1: endedAt must be a string or null")
            }
            if state == .active, endedAt != nil {
                throw ChronicleError("active Chronicle session \(id) has an endedAt timestamp")
            }
            guard let ide = object["ide"]?.objectValue else {
                throw ChronicleError("sessions.json does not match schema 1: ide must be an object")
            }
            try validateNonempty(
                try registryString(ide, "product", label: "ide.product"), name: "ide.product")
            try validateNonempty(
                try registryString(ide, "version", label: "ide.version"), name: "ide.version")
            guard let pid = integer(object["pid"]), pid >= 0 else {
                throw ChronicleError("sessions.json does not match schema 1: pid must be a non-negative integer")
            }
            if pid == 0 {
                throw ChronicleError("Chronicle session \(id) has an invalid pid")
            }
            guard let repositoriesValue = object["repositories"]?.arrayValue else {
                throw ChronicleError("sessions.json does not match schema 1: repositories must be an array")
            }
            var repositories: [IDERepository] = []
            for repository in repositoriesValue {
                guard let repositoryObject = repository.objectValue else {
                    throw ChronicleError(
                        "sessions.json does not match schema 1: repositories entries must be objects")
                }
                let repositoryRoot = try registryString(
                    repositoryObject, "root", label: "repositories[].root")
                try validateAbsolutePath(repositoryRoot, name: "repositories[].root")
                var branch: String?
                switch repositoryObject["branch"] {
                case .none, .some(.null):
                    branch = nil
                case .some(.string(let value)):
                    branch = value
                default:
                    throw ChronicleError(
                        "sessions.json does not match schema 1: repositories[].branch must be a string or null")
                }
                repositories.append(IDERepository(root: repositoryRoot, branch: branch))
            }
            candidates.append(
                IDESessionCandidate(
                    id: id, state: state, logPath: logPath, projectName: projectName,
                    projectRoot: projectRoot, repositories: repositories,
                    startedAt: startedAt, lastEventAt: lastEventAt, endedAt: endedAt))
        }
        return candidates
    }

    private static func registryString(
        _ object: [String: JSONValue], _ key: String, label: String
    ) throws -> String {
        guard let value = object[key]?.stringValue else {
            throw ChronicleError("sessions.json does not match schema 1: \(label) must be a string")
        }
        return value
    }

    private static func integer(_ value: JSONValue?) -> Int64? {
        guard let number = value?.numberValue, number == number.rounded(),
            abs(number) < 9_007_199_254_740_992
        else { return nil }
        return Int64(number)
    }

    // MARK: - Candidate matching

    static func matchCandidates(
        _ candidates: [IDESessionCandidate], repo: String,
        sessionStart: String, sessionEnd: String?
    ) -> [IDESessionCandidate] {
        let repo = GitClient.canonicalize(repo)
        var matches = candidates.filter { candidate in
            candidate.repositories.contains { GitClient.canonicalize($0.root) == repo }
        }
        if matches.contains(where: { $0.state == .active }) {
            matches = matches.filter { $0.state == .active }
        }
        if matches.contains(where: { overlaps($0, sessionStart: sessionStart, sessionEnd: sessionEnd) }) {
            matches = matches.filter { overlaps($0, sessionStart: sessionStart, sessionEnd: sessionEnd) }
        }
        return matches.sorted { $0.startedAt > $1.startedAt }
    }

    private static func overlaps(
        _ candidate: IDESessionCandidate, sessionStart: String, sessionEnd: String?
    ) -> Bool {
        guard let candidateStart = ChronicleTimestamp.date(from: candidate.startedAt),
            let candidateEnd = ChronicleTimestamp.date(from: candidate.endedAt ?? candidate.lastEventAt),
            let start = ChronicleTimestamp.date(from: sessionStart)
        else { return false }
        let end = sessionEnd.flatMap(ChronicleTimestamp.date(from:)) ?? Date()
        return candidateStart <= end && candidateEnd >= start
    }

    // MARK: - Chunk parsing

    static func parseChunk(
        _ bytes: Data, candidate: IDESessionCandidate,
        previousSequence: Int64, previousType: String?, observedAt: String
    ) throws -> ParsedIDEChunk {
        var consumed = 0
        var lastSequence = previousSequence
        var lastType = previousType
        var events: [NormalizedEvent] = []
        var ids = Set<String>()
        let newline = UInt8(ascii: "\n")
        let bytes = [UInt8](bytes)
        // A failing record aborts the chunk (fail-closed), but the failure
        // carries the valid prefix and the position just past the record so
        // the user can explicitly skip it.
        func fail(_ error: Error, recordSequence: Int64?) -> IDELogFailure {
            IDELogFailure(
                message: messageText(error), events: events, consumed: consumed,
                nextSequence: max(recordSequence ?? 0, lastSequence + 1))
        }
        while let relativeEnd = bytes[consumed...].firstIndex(of: newline) {
            var line = bytes[consumed..<relativeEnd]
            if line.last == UInt8(ascii: "\r") {
                line = line.dropLast()
            }
            consumed = relativeEnd + 1
            if line.isEmpty {
                throw fail(
                    ChronicleError("empty JSONL record at sequence \(lastSequence + 1)"),
                    recordSequence: nil)
            }
            if lastType == "session_ended" {
                throw fail(
                    ChronicleError("session_ended is not the final Chronicle record"),
                    recordSequence: nil)
            }
            let envelope: IDEEnvelope
            do {
                envelope = try parseEnvelope(Data(line), atSequence: lastSequence + 1)
            } catch {
                throw fail(error, recordSequence: nil)
            }
            do {
                try validateEnvelope(envelope, candidate: candidate, expectedSequence: lastSequence + 1)
            } catch {
                throw fail(error, recordSequence: envelope.sequence)
            }
            guard ids.insert(envelope.id).inserted else {
                throw fail(
                    ChronicleError("duplicate Chronicle event id \(envelope.id)"),
                    recordSequence: envelope.sequence)
            }
            lastSequence = envelope.sequence
            lastType = envelope.kind
            var payload: [String: JSONValue] = [
                "recordedAt": .string(envelope.recordedAt),
                "data": envelope.data,
            ]
            if envelope.redacted == true {
                payload["redacted"] = .bool(true)
                payload["contentTrust"] = .string("untrusted; read the referenced file")
            } else {
                payload["contentTrust"] = .string("trusted")
            }
            events.append(
                NormalizedEvent(
                    stableId: envelope.id, source: SourceName.ide,
                    streamId: candidate.id, sourceSequence: envelope.sequence,
                    occurredAt: envelope.occurredAt, observedAt: observedAt,
                    kind: envelope.kind, payload: .object(payload)))
        }
        if lastType == "session_ended", consumed < bytes.count {
            throw ChronicleError("session_ended is not the final Chronicle record")
        }
        events.sort {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return ($0.sourceSequence ?? 0) < ($1.sourceSequence ?? 0)
        }
        return ParsedIDEChunk(
            events: events, consumed: consumed, lastSequence: lastSequence, lastType: lastType)
    }

    struct IDEEnvelope {
        var schemaVersion: Int64
        var id: String
        var sessionId: String
        var sequence: Int64
        var kind: String
        var occurredAt: String
        var recordedAt: String
        var redacted: Bool?
        var data: JSONValue
    }

    private static func parseEnvelope(_ line: Data, atSequence sequence: Int64) throws -> IDEEnvelope {
        func malformed(_ detail: String) -> ChronicleError {
            ChronicleError("malformed complete JSONL record at sequence \(sequence): \(detail)")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            throw malformed(error.localizedDescription)
        }
        guard let object = value.objectValue else {
            throw malformed("record must be an object")
        }
        let allowed: Set<String> = [
            "schemaVersion", "id", "sessionId", "sequence", "type",
            "occurredAt", "recordedAt", "redacted", "data",
        ]
        for key in object.keys where !allowed.contains(key) {
            throw malformed("unknown field \(key)")
        }
        guard let schemaVersion = integer(object["schemaVersion"]) else {
            throw malformed("schemaVersion must be an integer")
        }
        guard let id = object["id"]?.stringValue else {
            throw malformed("id must be a string")
        }
        guard let sessionId = object["sessionId"]?.stringValue else {
            throw malformed("sessionId must be a string")
        }
        guard let eventSequence = integer(object["sequence"]), eventSequence >= 0 else {
            throw malformed("sequence must be a non-negative integer")
        }
        guard let kind = object["type"]?.stringValue else {
            throw malformed("type must be a string")
        }
        guard let occurredAt = object["occurredAt"]?.stringValue else {
            throw malformed("occurredAt must be a string")
        }
        guard let recordedAt = object["recordedAt"]?.stringValue else {
            throw malformed("recordedAt must be a string")
        }
        var redacted: Bool?
        switch object["redacted"] {
        case .none:
            redacted = nil
        case .some(.bool(let value)):
            redacted = value
        default:
            throw malformed("redacted must be a boolean")
        }
        guard let data = object["data"] else {
            throw malformed("data is missing")
        }
        return IDEEnvelope(
            schemaVersion: schemaVersion, id: id, sessionId: sessionId, sequence: eventSequence,
            kind: kind, occurredAt: occurredAt, recordedAt: recordedAt, redacted: redacted, data: data)
    }

    private static func validateEnvelope(
        _ envelope: IDEEnvelope, candidate: IDESessionCandidate, expectedSequence: Int64
    ) throws {
        if envelope.schemaVersion != 1 {
            throw ChronicleError(
                "unsupported event schemaVersion \(envelope.schemaVersion) at sequence \(envelope.sequence)")
        }
        try validateNonempty(envelope.id, name: "event id")
        if envelope.sessionId != candidate.id {
            throw ChronicleError(
                "event sessionId \(envelope.sessionId) does not match \(candidate.id)")
        }
        if envelope.sequence != expectedSequence {
            throw ChronicleError(
                "expected Chronicle sequence \(expectedSequence), found \(envelope.sequence)")
        }
        if envelope.sequence == 1, envelope.kind != "session_started" {
            throw ChronicleError("Chronicle sequence 1 must be session_started")
        }
        if envelope.sequence != 1, envelope.kind == "session_started" {
            throw ChronicleError("session_started must be Chronicle sequence 1")
        }
        if envelope.redacted == false {
            throw ChronicleError("redacted may only be present with the value true")
        }
        try validateWireTimestamp(envelope.occurredAt, name: "occurredAt")
        try validateWireTimestamp(envelope.recordedAt, name: "recordedAt")
        try validateEventData(kind: envelope.kind, data: envelope.data, candidate: candidate)
    }

    // MARK: - Event data validation

    private static func validateEventData(
        kind: String, data: JSONValue, candidate: IDESessionCandidate
    ) throws {
        guard let object = data.objectValue else {
            throw ChronicleError("\(kind).data must be an object")
        }
        switch kind {
        case "session_started":
            try validateKeys(
                object, required: ["projectName", "projectRoot", "repositories", "ide", "pid"],
                optional: [], context: kind)
            _ = try requireString(object, "projectName", context: kind)
            let root = try requireString(object, "projectRoot", context: kind)
            try validateAbsolutePath(root, name: "session_started.projectRoot")
            if root != candidate.projectRoot {
                throw ChronicleError("session_started.projectRoot does not match sessions.json")
            }
            if try requireString(object, "projectName", context: kind) != candidate.projectName {
                throw ChronicleError("session_started.projectName does not match sessions.json")
            }
            guard let repositories = object["repositories"]?.arrayValue else {
                throw ChronicleError("session_started.repositories must be an array")
            }
            for repository in repositories {
                guard let repository = repository.objectValue else {
                    throw ChronicleError("session_started repository must be an object")
                }
                try validateKeys(
                    object: repository, required: ["root", "branch"], optional: [],
                    context: "session_started repository")
                try validateAbsolutePath(
                    try requireString(repository, "root", context: "session_started repository"),
                    name: "session_started.repositories[].root")
                try requireNullableString(repository, "branch", context: "session_started repository")
            }
            guard let ide = object["ide"]?.objectValue else {
                throw ChronicleError("session_started.ide must be an object")
            }
            try validateKeys(
                object: ide, required: ["product", "version"], optional: [],
                context: "session_started.ide")
            _ = try requireString(ide, "product", context: "session_started.ide")
            _ = try requireString(ide, "version", context: "session_started.ide")
            _ = try requireInteger(object, "pid", context: kind)
        case "session_ended":
            try validateKeys(object, required: ["reason", "state"], optional: [], context: kind)
            let reason = try requireString(object, "reason", context: kind)
            guard ["stopped", "shutdown", "restarted", "error"].contains(reason) else {
                throw ChronicleError("invalid session_ended reason \(reason)")
            }
            let state = try requireString(object, "state", context: kind)
            guard ["completed", "interrupted"].contains(state) else {
                throw ChronicleError("invalid session_ended state \(state)")
            }
            if candidate.state != .active, state != candidate.state.rawValue {
                throw ChronicleError("session_ended state does not match sessions.json")
            }
        case "file_opened", "file_closed", "file_created", "file_deleted":
            try validateKeys(object, required: ["path"], optional: [], context: kind)
            try validateEventPath(try requireString(object, "path", context: kind), candidate: candidate)
        case "file_selected":
            try validateKeys(object, required: ["path"], optional: ["previousPath"], context: kind)
            try validateEventPath(try requireString(object, "path", context: kind), candidate: candidate)
            if let previous = try optionalString(object, "previousPath", context: kind) {
                try validateEventPath(previous, candidate: candidate)
            }
        case "file_renamed", "file_moved":
            try validateKeys(object, required: ["oldPath", "newPath"], optional: [], context: kind)
            try validateEventPath(try requireString(object, "oldPath", context: kind), candidate: candidate)
            try validateEventPath(try requireString(object, "newPath", context: kind), candidate: candidate)
        case "selection":
            try validateKeys(
                object, required: ["path", "startLine", "endLine"], optional: ["text"], context: kind)
            try validateEventPath(try requireString(object, "path", context: kind), candidate: candidate)
            let start = try requireInteger(object, "startLine", context: kind)
            let end = try requireInteger(object, "endLine", context: kind)
            if start > end {
                throw ChronicleError("selection.startLine must not exceed endLine")
            }
            _ = try optionalString(object, "text", context: kind)
        case "visible_area":
            try validateKeys(
                object, required: ["path", "startLine", "endLine"], optional: [], context: kind)
            try validateEventPath(try requireString(object, "path", context: kind), candidate: candidate)
            let start = try requireInteger(object, "startLine", context: kind)
            let end = try requireInteger(object, "endLine", context: kind)
            if start > end {
                throw ChronicleError("visible_area.startLine must not exceed endLine")
            }
        case "document_changed":
            try validateKeys(object, required: ["path", "lineCount"], optional: [], context: kind)
            try validateEventPath(try requireString(object, "path", context: kind), candidate: candidate)
            _ = try requireInteger(object, "lineCount", context: kind)
        case "branch_changed":
            try validateKeys(object, required: ["repository", "state"], optional: ["branch"], context: kind)
            try validateAbsolutePath(
                try requireString(object, "repository", context: kind),
                name: "branch_changed.repository")
            _ = try optionalString(object, "branch", context: kind)
            _ = try requireString(object, "state", context: kind)
        case "search":
            try validateKeys(object, required: ["query"], optional: [], context: kind)
            _ = try requireString(object, "query", context: kind)
        case "refactoring":
            try validateKeys(object, required: ["refactoringType", "details"], optional: [], context: kind)
            _ = try requireString(object, "refactoringType", context: kind)
            _ = try requireString(object, "details", context: kind)
        case "refactoring_undo":
            try validateKeys(object, required: ["refactoringType"], optional: [], context: kind)
            _ = try requireString(object, "refactoringType", context: kind)
        case "shell_command":
            try validateKeys(
                object, required: ["command", "shell"], optional: ["workingDirectory"], context: kind)
            _ = try requireString(object, "command", context: kind)
            _ = try requireString(object, "shell", context: kind)
            if let directory = try optionalString(object, "workingDirectory", context: kind) {
                try validateEventPath(directory, candidate: candidate)
            }
        case "audio_transcription":
            throw ChronicleError("audio_transcription is never valid in a Chronicle session log")
        default:
            throw ChronicleError("unknown Chronicle event type \(kind)")
        }
    }

    private static func validateKeys(
        _ object: [String: JSONValue], required: [String], optional: [String], context: String
    ) throws {
        try validateKeys(object: object, required: required, optional: optional, context: context)
    }

    private static func validateKeys(
        object: [String: JSONValue], required: [String], optional: [String], context: String
    ) throws {
        for key in required where object[key] == nil {
            throw ChronicleError("\(context).data is missing \(key)")
        }
        for key in object.keys.sorted() where !required.contains(key) && !optional.contains(key) {
            throw ChronicleError("\(context).data contains unknown field \(key)")
        }
    }

    private static func requireString(
        _ object: [String: JSONValue], _ key: String, context: String
    ) throws -> String {
        guard let value = object[key]?.stringValue else {
            throw ChronicleError("\(context).data.\(key) must be a string")
        }
        try validateNonempty(value, name: "\(context).data.\(key)")
        return value
    }

    private static func optionalString(
        _ object: [String: JSONValue], _ key: String, context: String
    ) throws -> String? {
        guard object[key] != nil else { return nil }
        return try requireString(object, key, context: context)
    }

    private static func requireNullableString(
        _ object: [String: JSONValue], _ key: String, context: String
    ) throws {
        switch object[key] {
        case .some(.null):
            return
        case .some(.string(let value)) where !value.trimmingCharacters(in: .whitespaces).isEmpty:
            return
        default:
            throw ChronicleError("\(context).\(key) must be a string or null")
        }
    }

    private static func requireInteger(
        _ object: [String: JSONValue], _ key: String, context: String
    ) throws -> Int64 {
        guard let value = integer(object[key]), value >= 0 else {
            throw ChronicleError("\(context).data.\(key) must be a non-negative integer")
        }
        return value
    }

    private static func validateNonempty(_ value: String, name: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChronicleError("\(name) must not be empty")
        }
    }

    private static func validateAbsolutePath(_ value: String, name: String) throws {
        try validateNonempty(value, name: name)
        if !value.hasPrefix("/") {
            throw ChronicleError("\(name) must be absolute: \(value)")
        }
    }

    private static func validateEventPath(_ value: String, candidate: IDESessionCandidate) throws {
        try validateNonempty(value, name: "event path")
        if value.hasPrefix("/") {
            let root = candidate.projectRoot.hasSuffix("/")
                ? candidate.projectRoot : candidate.projectRoot + "/"
            if value == candidate.projectRoot || value.hasPrefix(root) {
                throw ChronicleError("internal Chronicle path must be projectRoot-relative: \(value)")
            }
            return
        }
        let components = value.split(separator: "/")
        if components.contains("..") {
            throw ChronicleError("relative Chronicle path escapes projectRoot: \(value)")
        }
    }

    private static func validateWireTimestamp(_ value: String, name: String) throws {
        guard ChronicleTimestamp.isWireFormat(value) else {
            throw ChronicleError("\(name) must be UTC with exactly millisecond precision: \(value)")
        }
    }

    private static func messageText(_ error: Error) -> String {
        if let error = error as? ChronicleError {
            return error.message
        }
        return error.localizedDescription
    }
}

extension SourceName {
    /// Storage source for events imported from the IDE plugin (the health row
    /// uses "chronicle" for the plugin instead).
    public static let ide = "ide"
}
