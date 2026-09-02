import Foundation

public final class TupleClient: CallProvider {
    public let id = SourceName.tuple
    public let displayName = "Tuple"
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// `$TUPLE_BIN`, `/usr/local/bin/tuple`, `/opt/homebrew/bin/tuple`, then `tuple` on PATH.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TupleClient {
        if let bin = environment["TUPLE_BIN"], !bin.isEmpty {
            return TupleClient(executable: URL(fileURLWithPath: bin))
        }
        for candidate in ["/usr/local/bin/tuple", "/opt/homebrew/bin/tuple"] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                !isDirectory.boolValue
            {
                return TupleClient(executable: URL(fileURLWithPath: candidate))
            }
        }
        if let path = environment["PATH"] {
            for entry in path.split(separator: ":") {
                let candidate = "\(entry)/tuple"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return TupleClient(executable: URL(fileURLWithPath: candidate))
                }
            }
        }
        return TupleClient(executable: URL(fileURLWithPath: "tuple"))
    }

    public func currentCall() throws -> String? {
        let output = try run(arguments: ["call", "current", "--format", "json"])
        if !output.succeeded {
            if let diagnostic = output.diagnostic,
                diagnostic.lowercased().contains("not in a call")
            {
                return nil
            }
            throw ChronicleError(
                Self.commandError(
                    operation: "checking the current call",
                    command: "tuple call current --format json",
                    output: output))
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: output.stdout)
        } catch {
            throw ChronicleError("Tuple returned invalid current-call JSON: \(error.localizedDescription)")
        }
        let id = (value["id"] ?? value["call_id"] ?? value["callId"])?.stringValue
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChronicleError("Tuple current-call JSON did not contain an ID")
        }
        return id
    }

    public func collect(store: ChronicleStore, session: SessionRecord, timeout: String) throws {
        let lockURL = store.lockPath(source: "tuple", sessionId: session.id)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw ChronicleError("cannot open \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                // Another Chronicle process (GUI collector or CLI) is already
                // long-polling this call into the shared database and cursor;
                // waiting up to 2s behind its poll only adds latency.
                return
            }
            throw ChronicleError("cannot lock \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        defer { flock(descriptor, LOCK_UN) }

        // A batch a previous pass wrote but never committed (crash, database
        // timeout) replays first; stable IDs make the re-insert idempotent.
        try Self.drainSpool(store: store, session: session)

        let cursor = "chronicle-\(session.id)"
        let output = try run(arguments: [
            "--format", "json", "transcription", "show", session.id,
            "--wait", "--timeout", timeout, "--with-events", "--cursor", cursor,
        ])
        if !output.succeeded {
            let diagnostic = output.diagnostic ?? ""
            if Self.captureIsInactive(diagnostic) {
                let previouslyStarted = try store.sourceState(
                    sessionId: session.id, source: SourceName.tuple
                ).map { $0.status == "live" || $0.status == "stopped" } ?? false
                let (status, detail) =
                    previouslyStarted
                    ? ("stopped", "Transcription stopped during the call. Restart it in Tuple if intended.")
                    : ("waiting", "Call found. Waiting for transcription — start it in Tuple.")
                try store.setSourceState(
                    sessionId: session.id, source: SourceName.tuple, status: status, detail: detail)
                return
            }
            let error = Self.commandError(
                operation: "reading this call's Capture transcript",
                command:
                    "tuple --format json transcription show \(session.id) --wait --timeout \(timeout) --with-events --cursor \(cursor)",
                output: output)
            try store.setSourceState(
                sessionId: session.id, source: SourceName.tuple, status: "error", detail: error)
            throw ChronicleError(error)
        }

        // Tuple's durable cursor has already advanced past this batch, so it
        // is spooled to disk before the database write; a crash or timeout in
        // between leaves the file for the next pass instead of losing speech.
        let spooled = Self.spool(output.stdout, store: store, session: session)
        try Self.apply(batch: TupleRecordParser.parse(output.stdout), store: store, session: session)
        if let spooled {
            try? FileManager.default.removeItem(at: spooled)
        }
        try Self.escalatePersistentGap(store: store, session: session)
    }

    static func apply(batch: ParsedTupleBatch, store: ChronicleStore, session: SessionRecord) throws {
        try store.insertSourceEvents(sessionId: session.id, events: batch.events)
        if let status = batch.status {
            try store.setSourceState(
                sessionId: session.id, source: SourceName.tuple,
                status: status.status, detail: status.detail)
        }
        if batch.malformed > 0 {
            try store.setSourceState(
                sessionId: session.id, source: SourceName.tuple, status: "error",
                detail:
                    "Ignored \(batch.malformed) malformed Tuple record\(batch.malformed == 1 ? "" : "s"); durable records were kept.")
        }
        if batch.callEnded {
            try store.markCallEnded(session.id)
        }
    }

    // MARK: - Spool

    /// Spool files older than this are orphans (their session was pruned or
    /// renamed); a crashed pass is drained seconds later, not a day later.
    static let spoolExpiry: TimeInterval = 24 * 3600

    private static func spoolPrefix(sessionId: String) -> String {
        "tuple-\(ChroniclePaths.safeSessionId(sessionId))-"
    }

    /// Writes the raw batch beside the database. Best-effort: a spool failure
    /// falls back to the previous (unspooled) behavior rather than dropping
    /// the batch that is already in hand.
    static func spool(_ bytes: Data, store: ChronicleStore, session: SessionRecord) -> URL? {
        guard !bytes.isEmpty else { return nil }
        let directory = store.paths.spoolDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let name = spoolPrefix(sessionId: session.id)
            + String(format: "%015d", milliseconds)
            + "-\(UUID().uuidString).ndjson"
        let url = directory.appendingPathComponent(name)
        do {
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func drainSpool(store: ChronicleStore, session: SessionRecord) throws {
        let directory = store.paths.spoolDirectory
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let prefix = spoolPrefix(sessionId: session.id)
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if url.lastPathComponent.hasPrefix(prefix) {
                if let bytes = try? Data(contentsOf: url) {
                    try apply(batch: TupleRecordParser.parse(bytes), store: store, session: session)
                }
                try? FileManager.default.removeItem(at: url)
            } else if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                Date().timeIntervalSince(modified) > spoolExpiry
            {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// A `transcription_dropped` only surfaces as a stopped source when it is
    /// still the latest Tuple record after this grace period; speech resuming
    /// (or Tuple's own lifecycle records) clears it silently.
    static let gapGracePeriod: TimeInterval = 30

    static func escalatePersistentGap(
        store: ChronicleStore, session: SessionRecord, now: Date = Date()
    ) throws {
        guard let latest = try store.latestSourceEvent(sessionId: session.id, source: SourceName.tuple),
            latest.kind == "transcription_dropped",
            let observed = ChronicleTimestamp.date(from: latest.observedAt),
            now.timeIntervalSince(observed) >= gapGracePeriod,
            try store.sourceState(sessionId: session.id, source: SourceName.tuple)?.status == "live"
        else { return }
        try store.setSourceState(
            sessionId: session.id, source: SourceName.tuple, status: "stopped",
            detail:
                "Tuple reported a transcription gap that has not recovered. Chronicle will not restart it automatically.")
    }

    // MARK: - Process handling

    struct ProcessOutput {
        var succeeded: Bool
        var statusDescription: String
        var stdout: Data
        var stderr: Data

        var diagnostic: String? {
            let stderrText = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutText = String(decoding: stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch (stderrText.isEmpty, stdoutText.isEmpty) {
            case (false, false) where stderrText == stdoutText: return stderrText
            case (false, false): return "\(stderrText) (stdout: \(stdoutText))"
            case (false, true): return stderrText
            case (true, false): return stdoutText
            case (true, true): return nil
            }
        }
    }

    private func run(arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw ChronicleError(Self.launchError(path: executable, underlying: error))
        }
        // Drain stderr off-thread so a full pipe can never deadlock large stdout reads.
        let group = DispatchGroup()
        nonisolated(unsafe) var stderrData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let statusDescription: String
        if process.terminationReason == .uncaughtSignal {
            statusDescription = "signal: \(process.terminationStatus)"
        } else {
            statusDescription = "exit status: \(process.terminationStatus)"
        }
        return ProcessOutput(
            succeeded: process.terminationReason == .exit && process.terminationStatus == 0,
            statusDescription: statusDescription,
            stdout: stdout, stderr: stderrData)
    }

    // MARK: - Diagnostics

    static func captureIsInactive(_ diagnostic: String) -> Bool {
        let detail = diagnostic.lowercased()
        let authorization = [
            "not authorized", "unauthorized", "authorization denied",
            "permission denied", "access denied", "forbidden",
        ]
        if authorization.contains(where: detail.contains) {
            return false
        }
        return [
            "transcription is not running", "transcription not running", "no transcription",
            "no recording", "capture is not running", "capture not running", "not transcribing",
            // A call that is still connecting exists in `tuple call current`
            // before Tuple's transcription store has a record for it.
            "no stored call matching",
        ].contains(where: detail.contains)
    }

    static func commandError(operation: String, command: String, output: ProcessOutput) -> String {
        let diagnostic = output.diagnostic
        let lower = (diagnostic ?? "").lowercased()
        let macosPermission = [
            ("microphone", "Microphone"),
            ("screen recording", "Screen & System Audio Recording"),
            ("screen capture", "Screen & System Audio Recording"),
            ("accessibility", "Accessibility"),
        ].first { lower.contains($0.0) }
        let deniedSignals = [
            "permission", "denied", "not allowed", "not authorized", "not permitted",
        ]
        let explanation: String
        if let (_, permission) = macosPermission, deniedSignals.contains(where: lower.contains) {
            explanation =
                "Tuple is missing its macOS \(permission) permission. Open System Settings → Privacy & Security → \(permission), allow Tuple, then retry."
        } else if ["tuple.sock", "dial unix", "connection refused", "connect: no such file"]
            .contains(where: lower.contains)
        {
            explanation = "Chronicle cannot reach Tuple. Open the Tuple app and make sure it is running."
        } else if [
            "not authorized", "unauthorized", "authorization denied",
            "permission denied", "access denied", "forbidden",
        ].contains(where: lower.contains) {
            explanation =
                "Tuple CLI access is not authorized. Open Tuple Settings → Integrations → CLI Server, allow access, then retry."
        } else if [
            "not signed in", "not logged in", "is tuple logged in",
            "no current user", "authentication required",
        ].contains(where: lower.contains) {
            explanation = "Tuple is not signed in. Sign in to the Tuple app, then retry."
        } else if lower.contains("transcription store unavailable") {
            explanation =
                "Tuple Capture has not been initialized on this Mac. Start Capture once in Tuple, then retry."
        } else if diagnostic == nil {
            explanation =
                "The Tuple CLI returned no diagnostic output. Run the command below in Terminal; if it also fails silently, reopen Tuple and reinstall or re-authorize the CLI Server integration."
        } else {
            explanation =
                "Tuple returned an unrecognized error. Run the command below in Terminal and use Tuple's exact diagnostic to resolve it."
        }
        if let diagnostic {
            return
                "Tuple failed while \(operation) (\(output.statusDescription)). \(explanation) Command: `\(command)`. Tuple said: \(diagnostic)"
        }
        return "Tuple failed while \(operation) (\(output.statusDescription)). \(explanation) Command: `\(command)`."
    }

    static func launchError(path: URL, underlying error: Error) -> String {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path.path) {
            return
                "Tuple CLI was not found at \(path.path). Open Tuple Settings → Integrations → CLI Server and choose Install CLI."
        }
        if !fileManager.isExecutableFile(atPath: path.path) {
            return
                "Tuple CLI at \(path.path) is not executable (\(error.localizedDescription)). Reinstall it from Tuple Settings → Integrations → CLI Server."
        }
        return
            "Tuple CLI at \(path.path) could not start (\(error.localizedDescription)). Open Tuple and reinstall or re-authorize it in Settings → Integrations → CLI Server."
    }
}

// MARK: - Record normalization

struct TupleStatusUpdate: Equatable {
    var status: String
    var detail: String
}

struct ParsedTupleBatch {
    var events: [NormalizedEvent] = []
    var status: TupleStatusUpdate?
    var callEnded = false
    var malformed = 0
}

enum TupleRecordParser {
    static func parse(_ bytes: Data) -> ParsedTupleBatch {
        let observedAt = ChronicleTimestamp.now()
        var batch = ParsedTupleBatch()
        for rawLine in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let line = trimASCIIWhitespace(rawLine)
            if line.isEmpty { continue }
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else {
                batch.malformed += 1
                continue
            }
            if record["kind"]?.stringValue == "status" {
                if record["status"]?.stringValue == "call_ended" {
                    batch.callEnded = true
                    batch.status = TupleStatusUpdate(
                        status: "ended", detail: "Call ended. The agent is finishing the handoff.")
                    batch.events.append(
                        NormalizedEvent(
                            stableId: "tuple:call-ended", source: SourceName.tuple,
                            occurredAt: observedAt, observedAt: observedAt,
                            kind: "call_ended", payload: record))
                }
                continue
            }
            let kind = record["type"]?.stringValue ?? "unknown"
            if kind == "user_audio_started" || kind == "user_audio_stopped" { continue }
            let data = record["data"]
            let occurredValue: JSONValue?
            if kind == "transcription_finished" {
                occurredValue = data?["start"] ?? record["time"]
            } else {
                occurredValue = record["time"]
            }
            let occurredAt = normalizeTimestamp(occurredValue, fallback: observedAt)
            let normalizedKind = kind == "transcription_finished" ? "speech" : kind
            if normalizedKind == "speech" {
                let text = data?["text"]?.stringValue
                if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    continue
                }
            }
            let identity = (record["id"] ?? data?["id"]).flatMap(valueIdentity)
            let stableId =
                identity.map { "tuple:\(kind):\($0)" }
                ?? "tuple:\(SHA256Hex.hash(Data(line)))"
            let payload: JSONValue
            if normalizedKind == "speech" {
                payload = .object([
                    "text": data?["text"] ?? .null,
                    "speakerId": data?["user_id"] ?? .null,
                    "raw": record,
                ])
            } else {
                payload = record
            }
            batch.events.append(
                NormalizedEvent(
                    stableId: stableId, source: SourceName.tuple,
                    occurredAt: occurredAt, observedAt: observedAt,
                    kind: normalizedKind, payload: payload))
            switch kind {
            case "transcription_finished", "transcription_started", "recording_started":
                batch.status = TupleStatusUpdate(status: "live", detail: "Transcription is live.")
            case "transcription_dropped":
                // Brief gaps are routine while Tuple keeps transcribing; the
                // collector escalates only a gap that persists (see
                // `TupleClient.escalatePersistentGap`).
                break
            case "recording_ended", "transcription_ended":
                batch.status = TupleStatusUpdate(
                    status: "stopped",
                    detail: "Transcription stopped during the call. Restart it in Tuple if intended.")
            default:
                break
            }
        }
        batch.events.sort {
            ($0.occurredAt, $0.stableId) < ($1.occurredAt, $1.stableId)
        }
        return batch
    }

    /// Accepts RFC 3339 (any offset), numeric strings, and epoch seconds or
    /// milliseconds (`< 1e11` means seconds), normalized to the wire format.
    static func normalizeTimestamp(_ value: JSONValue?, fallback: String) -> String {
        switch value {
        case .string(let text):
            if let date = parseRFC3339(text) {
                return ChronicleTimestamp.string(from: date)
            }
            if let number = Double(text) {
                return timestampFromNumber(number) ?? fallback
            }
            return fallback
        case .number(let number):
            return timestampFromNumber(number) ?? fallback
        default:
            return fallback
        }
    }

    private static func parseRFC3339(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let wholeSecond = ISO8601DateFormatter()
        wholeSecond.formatOptions = [.withInternetDateTime]
        return wholeSecond.date(from: text)
    }

    private static func timestampFromNumber(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        let milliseconds = abs(value) < 100_000_000_000.0 ? value * 1000.0 : value
        let date = Date(timeIntervalSince1970: milliseconds.rounded() / 1000.0)
        return ChronicleTimestamp.string(from: date)
    }

    private static func valueIdentity(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 {
                return String(Int64(number))
            }
            return String(number)
        case .object(let object):
            return object["id"].flatMap(valueIdentity)
        default:
            return nil
        }
    }

    private static func trimASCIIWhitespace(_ bytes: Data.SubSequence) -> Data.SubSequence {
        var slice = bytes
        while let first = slice.first, first == 0x20 || first == 0x09 || first == 0x0D || first == 0x0A {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == 0x20 || last == 0x09 || last == 0x0D || last == 0x0A {
            slice = slice.dropLast()
        }
        return slice
    }
}
