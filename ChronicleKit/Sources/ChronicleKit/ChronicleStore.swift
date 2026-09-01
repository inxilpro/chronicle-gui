import Foundation
import GRDB

public struct SessionRecord: Sendable, Equatable {
    public var id: String
    public var state: SessionState
    public var startedAt: String
    public var repoPath: String?
    public var notesPath: String
    public var savedHash: String?

    public init(
        id: String, state: SessionState, startedAt: String,
        repoPath: String? = nil, notesPath: String, savedHash: String? = nil
    ) {
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.repoPath = repoPath
        self.notesPath = notesPath
        self.savedHash = savedHash
    }
}

public struct StoredSourceState: Sendable, Equatable {
    public var status: String
    public var detail: String?
    public var cursorJson: String?

    public init(status: String, detail: String? = nil, cursorJson: String? = nil) {
        self.status = status
        self.detail = detail
        self.cursorJson = cursorJson
    }
}

public final class ChronicleStore: Sendable {
    public static let retainedTerminalSessions = 5

    public let paths: ChroniclePaths
    let environment: [String: String]
    private let pool: DatabasePool

    public init(
        paths: ChroniclePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.paths = paths
        self.environment = environment
        let fileManager = FileManager.default
        for directory in [paths.sessionsDirectory, paths.locksDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ChronicleError(
                    "cannot create Chronicle storage at \(paths.appHome.path): \(error.localizedDescription)")
            }
        }
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        pool = try DatabasePool(path: paths.databaseURL.path, configuration: configuration)
        try Self.migrator.migrate(pool)
    }

    /// The GUI observes this reader with GRDB ValueObservation.
    public var databaseReader: any DatabaseReader { pool }

    // MARK: - Migrations

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE sessions (
                        id TEXT PRIMARY KEY,
                        state TEXT NOT NULL CHECK (state IN ('active','finalizing','complete','interrupted')),
                        started_at TEXT NOT NULL, call_ended_at TEXT, finished_at TEXT, updated_at TEXT NOT NULL,
                        repo_path TEXT, notes_path TEXT NOT NULL UNIQUE,
                        saved_hash TEXT, saved_at TEXT, saved_destination TEXT,
                        data_pruned INTEGER NOT NULL DEFAULT 0 CHECK (data_pruned IN (0,1))
                    );
                    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE source_events (
                        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        stable_id TEXT NOT NULL, source TEXT NOT NULL,
                        stream_id TEXT, source_sequence INTEGER,
                        occurred_at TEXT NOT NULL, observed_at TEXT NOT NULL,
                        kind TEXT NOT NULL, payload_json TEXT NOT NULL,
                        UNIQUE (session_id, source, stable_id)
                    );
                    CREATE INDEX source_events_consumer_order ON source_events(session_id, sequence);
                    CREATE INDEX source_events_chronology ON source_events(session_id, occurred_at, sequence);
                    CREATE UNIQUE INDEX source_events_stream ON source_events(session_id, source, stream_id, source_sequence)
                        WHERE stream_id IS NOT NULL AND source_sequence IS NOT NULL;
                    CREATE TABLE source_state (
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        source TEXT NOT NULL, status TEXT NOT NULL, detail TEXT,
                        cursor_json TEXT, updated_at TEXT NOT NULL, PRIMARY KEY (session_id, source)
                    );
                    CREATE TABLE chat_messages (
                        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        id TEXT NOT NULL,
                        kind TEXT NOT NULL CHECK (kind IN ('message','ack','decision')),
                        timestamp TEXT NOT NULL, text TEXT NOT NULL, reference_json TEXT,
                        read INTEGER NOT NULL CHECK (read IN (0,1)),
                        decision_status TEXT CHECK (decision_status IN ('unreviewed','approved','rejected')),
                        UNIQUE (session_id, id)
                    );
                    CREATE TABLE file_references (
                        session_id TEXT NOT NULL, message_id TEXT NOT NULL, position INTEGER NOT NULL,
                        path TEXT NOT NULL, line INTEGER, end_line INTEGER, sha TEXT NOT NULL,
                        PRIMARY KEY (session_id, message_id, position),
                        FOREIGN KEY (session_id, message_id) REFERENCES chat_messages(session_id, id) ON DELETE CASCADE
                    );
                    CREATE TABLE decision_reviews (
                        session_id TEXT NOT NULL, decision_id TEXT NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('approved','rejected')),
                        reviewed_at TEXT NOT NULL,
                        PRIMARY KEY (session_id, decision_id),
                        FOREIGN KEY (session_id, decision_id) REFERENCES chat_messages(session_id, id) ON DELETE CASCADE
                    );
                    CREATE TABLE consumer_cursors (
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        consumer TEXT NOT NULL, sequence INTEGER NOT NULL DEFAULT 0,
                        updated_at TEXT NOT NULL, PRIMARY KEY (session_id, consumer)
                    );
                    CREATE TABLE consumer_deliveries (
                        session_id TEXT NOT NULL, consumer TEXT NOT NULL,
                        event_sequence INTEGER NOT NULL REFERENCES source_events(sequence) ON DELETE CASCADE,
                        delivered_at TEXT NOT NULL,
                        PRIMARY KEY (session_id, consumer, event_sequence),
                        FOREIGN KEY (session_id, consumer) REFERENCES consumer_cursors(session_id, consumer) ON DELETE CASCADE
                    );
                    CREATE INDEX consumer_deliveries_lookup
                        ON consumer_deliveries(session_id, consumer, event_sequence);
                    CREATE TABLE ide_candidates (
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        id TEXT NOT NULL, candidate_json TEXT NOT NULL,
                        selected INTEGER NOT NULL DEFAULT 0 CHECK (selected IN (0,1)),
                        PRIMARY KEY (session_id, id)
                    );
                    """)
        }
        return migrator
    }()

    // MARK: - Transactions

    private func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try pool.writeWithoutTransaction { db in
            var result: Result<T, Error>?
            try db.inTransaction(.immediate) {
                result = Result { try updates(db) }
                if case .failure = result { return .rollback }
                return .commit
            }
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            case nil: throw ChronicleError("Chronicle database error: transaction did not run")
            }
        }
    }

    private func read<T>(_ value: (Database) throws -> T) throws -> T {
        try pool.read(value)
    }

    // MARK: - Sessions

    public func createOrResumeSession(callId: String) throws -> SessionRecord {
        if callId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChronicleError("Tuple returned an empty call ID")
        }
        let notes = paths.notesURL(sessionId: callId)
        let directory = notes.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ChronicleError("cannot create \(directory.path): \(error.localizedDescription)")
        }
        if !FileManager.default.fileExists(atPath: notes.path) {
            do {
                try Data().write(to: notes)
            } catch {
                throw ChronicleError("cannot create \(notes.path): \(error.localizedDescription)")
            }
        }
        let timestamp = ChronicleTimestamp.now()
        try write { db in
            try db.execute(
                sql: """
                    UPDATE sessions SET state = 'interrupted', finished_at = ?, updated_at = ?
                    WHERE state = 'active' AND id <> ?
                    """,
                arguments: [timestamp, timestamp, callId])
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, state, started_at, updated_at, notes_path)
                    VALUES (?, 'active', ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        updated_at = excluded.updated_at,
                        state = CASE
                            WHEN sessions.state = 'interrupted' THEN 'active'
                            ELSE sessions.state
                        END
                    """,
                arguments: [callId, timestamp, timestamp, notes.path])
            try db.execute(
                sql: """
                    INSERT INTO source_state (session_id, source, status, detail, updated_at)
                    VALUES (?, 'tuple', 'waiting', 'Call found. Start transcription in Tuple.', ?)
                    ON CONFLICT(session_id, source) DO NOTHING
                    """,
                arguments: [callId, timestamp])
            try Self.setSetting(db, key: "selected_session", value: callId)
        }
        return try session(callId)
    }

    public func session(_ id: String) throws -> SessionRecord {
        guard let record = try read({ db in try Self.querySession(db, where: "id = ?", arguments: [id]) })
        else {
            throw ChronicleError("session not found: \(id)")
        }
        return record
    }

    public func currentSession() throws -> SessionRecord? {
        try read { db in try Self.queryCurrentSession(db) }
    }

    public func selectedSession() throws -> SessionRecord? {
        try read { db in
            if let current = try Self.queryCurrentSession(db) {
                return current
            }
            if let id = try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = 'selected_session'"),
                let session = try Self.querySession(db, where: "id = ?", arguments: [id])
            {
                return session
            }
            return nil
        }
    }

    public func clearTerminalSelectionForLaunch() throws {
        try write { db in
            try db.execute(
                sql: """
                    DELETE FROM settings
                    WHERE key = 'selected_session'
                      AND value IN (SELECT id FROM sessions WHERE state IN ('complete', 'interrupted'))
                    """)
        }
    }

    public func selectSession(_ id: String) throws {
        try write { db in
            guard
                let state = try String.fetchOne(
                    db, sql: "SELECT state FROM sessions WHERE id = ?", arguments: [id])
            else {
                throw ChronicleError("session not found: \(id)")
            }
            if state == "active" || state == "finalizing" { return }
            try Self.setSetting(db, key: "selected_session", value: id)
        }
    }

    public func attachRepo(sessionId: String, repo: String) throws -> SessionRecord {
        let root = try GitClient.repositoryRoot(startingAt: repo)
        let timestamp = ChronicleTimestamp.now()
        try write { db in
            let changed = try db.executeWithChanges(
                sql: """
                    UPDATE sessions SET repo_path = ?, updated_at = ?
                    WHERE id = ? AND state IN ('active', 'finalizing')
                    """,
                arguments: [root, timestamp, sessionId])
            if changed == 0 {
                throw ChronicleError("active session not found: \(sessionId)")
            }
            try Self.upsertSourceState(
                db, sessionId: sessionId, source: SourceName.claude,
                status: "connected", detail: "Attached to \(root)", cursorJson: nil,
                timestamp: timestamp)
        }
        return try session(sessionId)
    }

    public func touchSession(_ sessionId: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE sessions SET updated_at = ? WHERE id = ? AND state = 'active'",
                arguments: [ChronicleTimestamp.now(), sessionId])
        }
    }

    public func markCallEnded(_ sessionId: String) throws {
        let timestamp = ChronicleTimestamp.now()
        try write { db in
            try db.execute(
                sql: """
                    UPDATE sessions SET state = 'finalizing', call_ended_at = ?, updated_at = ?
                    WHERE id = ? AND state = 'active'
                    """,
                arguments: [timestamp, timestamp, sessionId])
            try Self.upsertSourceState(
                db, sessionId: sessionId, source: SourceName.tuple,
                status: "ended", detail: "Call ended. Claude is finishing the handoff.",
                cursorJson: nil, timestamp: timestamp)
        }
    }

    public func finishSession(_ sessionId: String) throws {
        let timestamp = ChronicleTimestamp.now()
        let changed = try write { db in
            try db.executeWithChanges(
                sql: """
                    UPDATE sessions SET state = 'complete', finished_at = ?, updated_at = ?
                    WHERE id = ? AND state = 'finalizing'
                    """,
                arguments: [timestamp, timestamp, sessionId])
        }
        if changed == 0 {
            switch try session(sessionId).state {
            case .active:
                throw ChronicleError(
                    "Tuple call is still active; finish after Chronicle reports finalizing")
            case .complete:
                throw ChronicleError("session is already complete")
            case .interrupted:
                throw ChronicleError("an interrupted session cannot be finished")
            case .finalizing:
                throw ChronicleError("session could not be finished")
            }
        }
        try prune()
    }

    @discardableResult
    public func interruptStaleSessions(olderThan age: TimeInterval) throws -> Int {
        let cutoff = ChronicleTimestamp.string(from: Date().addingTimeInterval(-age))
        let timestamp = ChronicleTimestamp.now()
        let changed = try write { db in
            try db.executeWithChanges(
                sql: """
                    UPDATE sessions SET state = 'interrupted', finished_at = ?, updated_at = ?
                    WHERE state = 'active' AND updated_at < ?
                    """,
                arguments: [timestamp, timestamp, cutoff])
        }
        if changed > 0 {
            try prune()
        }
        return changed
    }

    /// `COALESCE(call_ended_at, finished_at)` for candidate-overlap checks.
    public func sessionEnd(_ sessionId: String) throws -> String? {
        try read { db in
            try String.fetchOne(
                db,
                sql: "SELECT COALESCE(call_ended_at, finished_at) FROM sessions WHERE id = ?",
                arguments: [sessionId])
        }
    }

    // MARK: - Settings

    public func setting(_ key: String) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ key: String, to value: String?) throws {
        try write { db in
            if let value {
                try Self.setSetting(db, key: key, value: value)
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    public func setTupleDiscoveryError(_ error: String?) throws {
        try setSetting("tuple_discovery_error", to: error)
    }

    public func tupleDiscoveryError() throws -> String? {
        try setting("tuple_discovery_error")
    }

    /// The IDE plugin's publish root: explicit setting, then `CHRONICLE_HOME`, then `~/.chronicle`.
    public func ideRoot() throws -> URL {
        ChroniclePaths.ideRoot(explicit: try setting("ide_root"), environment: environment)
    }

    @discardableResult
    public func setIDERoot(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ChronicleError("cannot resolve Chronicle IDE folder \(path): no such directory")
        }
        guard isDirectory.boolValue else {
            throw ChronicleError("Chronicle IDE folder is not a directory: \(path)")
        }
        let canonical = GitClient.canonicalize(url.path)
        try setSetting("ide_root", to: canonical)
        return canonical
    }

    // MARK: - Source state and events

    public func lockPath(source: String, sessionId: String) -> URL {
        paths.locksDirectory.appendingPathComponent(
            "\(source)-\(String(SHA256Hex.hash(sessionId).prefix(16))).lock")
    }

    public func setSourceState(
        sessionId: String, source: String, status: String,
        detail: String? = nil, cursorJson: String? = nil
    ) throws {
        let timestamp = ChronicleTimestamp.now()
        try write { db in
            try Self.upsertSourceState(
                db, sessionId: sessionId, source: source, status: status,
                detail: detail, cursorJson: cursorJson, timestamp: timestamp)
        }
    }

    public func sourceState(sessionId: String, source: String) throws -> StoredSourceState? {
        try read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT status, detail, cursor_json FROM source_state
                        WHERE session_id = ? AND source = ?
                        """,
                    arguments: [sessionId, source])
            else { return nil }
            return StoredSourceState(status: row["status"], detail: row["detail"], cursorJson: row["cursor_json"])
        }
    }

    @discardableResult
    public func insertSourceEvents(sessionId: String, events: [NormalizedEvent]) throws -> Int {
        if events.isEmpty { return 0 }
        let sorted = events.sorted {
            ($0.occurredAt, $0.stableId) < ($1.occurredAt, $1.stableId)
        }
        return try write { db in
            var inserted = 0
            for event in sorted {
                inserted += try Self.insertEvent(db, sessionId: sessionId, event: event)
            }
            try db.execute(
                sql: "UPDATE sessions SET updated_at = ? WHERE id = ?",
                arguments: [ChronicleTimestamp.now(), sessionId])
            return inserted
        }
    }

    public func sourceHealth(sessionId: String) throws -> [SourceHealth] {
        let session = try session(sessionId)
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT source, status, detail FROM source_state WHERE session_id = ?",
                arguments: [sessionId])
            func find(_ source: String) -> (status: String, detail: String?)? {
                rows.first { $0["source"] == source }.map { ($0["status"], $0["detail"]) }
            }
            let tuple = find(SourceName.tuple)
            let ide = find(SourceName.chronicle)
            return [
                Self.health(SourceName.tuple, tuple?.status ?? "waiting", tuple?.detail),
                session.repoPath != nil
                    ? SourceHealth(source: SourceName.claude, status: .connected, detail: "chronicle skill attached")
                    : SourceHealth(
                        source: SourceName.claude, status: .waiting,
                        detail: "Waiting for the chronicle skill to attach from a repository"),
                Self.health(SourceName.chronicle, ide?.status ?? "off", ide?.detail),
            ]
        }
    }

    // MARK: - Show (consumer delivery)

    public func show(sessionId: String, consumer: String, limit: Int) throws -> ShowResult {
        if consumer.trimmingCharacters(in: .whitespaces).isEmpty
            || consumer.contains(where: \.isWhitespace)
        {
            throw ChronicleError("cursor name must be non-empty and contain no whitespace")
        }
        if limit < 1 || limit > 10_000 {
            throw ChronicleError("show limit must be between 1 and 10000")
        }
        let session = try session(sessionId)
        let (events, hasMore) = try write { db -> ([NormalizedEvent], Bool) in
            try db.execute(
                sql: """
                    INSERT INTO consumer_cursors (session_id, consumer, sequence, updated_at)
                    VALUES (?, ?, 0, ?)
                    ON CONFLICT(session_id, consumer) DO NOTHING
                    """,
                arguments: [sessionId, consumer, ChronicleTimestamp.now()])
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT event.sequence, event.stable_id, event.source, event.stream_id,
                           event.source_sequence, event.occurred_at, event.observed_at,
                           event.kind, event.payload_json
                    FROM source_events AS event
                    LEFT JOIN consumer_deliveries AS delivery
                      ON delivery.session_id = event.session_id
                     AND delivery.consumer = ?
                     AND delivery.event_sequence = event.sequence
                    WHERE event.session_id = ? AND delivery.event_sequence IS NULL
                    ORDER BY event.occurred_at, event.sequence LIMIT ?
                    """,
                arguments: [consumer, sessionId, limit])
            let timestamp = ChronicleTimestamp.now()
            var delivered: [(Int64, NormalizedEvent)] = []
            for row in rows {
                let sequence: Int64 = row["sequence"]
                let payloadJson: String = row["payload_json"]
                let payload =
                    (try? JSONDecoder().decode(JSONValue.self, from: Data(payloadJson.utf8))) ?? .null
                delivered.append(
                    (
                        sequence,
                        NormalizedEvent(
                            stableId: row["stable_id"], source: row["source"],
                            streamId: row["stream_id"], sourceSequence: row["source_sequence"],
                            occurredAt: row["occurred_at"], observedAt: row["observed_at"],
                            kind: row["kind"], payload: payload)
                    ))
                try db.execute(
                    sql: """
                        INSERT INTO consumer_deliveries (session_id, consumer, event_sequence, delivered_at)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [sessionId, consumer, sequence, timestamp])
            }
            let hasMore =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM source_events AS event
                            LEFT JOIN consumer_deliveries AS delivery
                              ON delivery.session_id = event.session_id
                             AND delivery.consumer = ?
                             AND delivery.event_sequence = event.sequence
                            WHERE event.session_id = ? AND delivery.event_sequence IS NULL
                        )
                        """,
                    arguments: [consumer, sessionId]) ?? false
            if let highWater = delivered.map(\.0).max() {
                try db.execute(
                    sql: """
                        UPDATE consumer_cursors SET sequence = MAX(sequence, ?), updated_at = ?
                        WHERE session_id = ? AND consumer = ?
                        """,
                    arguments: [highWater, timestamp, sessionId, consumer])
            }
            return (delivered.map(\.1), hasMore)
        }
        return ShowResult(
            sessionId: session.id, sessionState: session.state,
            notesPath: session.notesPath, repoPath: session.repoPath,
            sourceHealth: try sourceHealth(sessionId: session.id),
            events: events, hasMore: hasMore)
    }

    public func hasUndeliveredEvents(sessionId: String, consumer: String) throws -> Bool {
        try read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM source_events AS event
                        LEFT JOIN consumer_deliveries AS delivery
                          ON delivery.session_id = event.session_id
                         AND delivery.consumer = ?
                         AND delivery.event_sequence = event.sequence
                        WHERE event.session_id = ? AND delivery.event_sequence IS NULL
                    )
                    """,
                arguments: [consumer, sessionId]) ?? false
        }
    }

    // MARK: - Chat

    public func makeMessage(
        session: SessionRecord, id: String, kind: MessageKind, text: String,
        reference: DocumentReference?, explicitFiles: [String]
    ) throws -> ChatMessage {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChronicleError("message text cannot be empty")
        }
        guard let repo = session.repoPath else {
            throw ChronicleError("the chronicle skill has not attached a repository")
        }
        var specs: [FileSpec] = []
        for spec in try explicitFiles.map(FileSpec.parse) + FileSpec.inferred(from: text)
        where !specs.contains(spec) {
            specs.append(spec)
        }
        let files: [FileReference]
        if specs.isEmpty {
            files = []
        } else {
            let sha = try GitClient.headSHA(repository: repo)
            files = specs.map { FileReference(path: $0.path, line: $0.line, endLine: $0.endLine, sha: sha) }
        }
        return ChatMessage(
            id: id, kind: kind, timestamp: ChronicleTimestamp.now(), text: text,
            reference: reference, files: files,
            read: kind == .ack,
            decisionStatus: kind == .decision ? .unreviewed : nil)
    }

    public func appendMessage(sessionId: String, message: ChatMessage) throws {
        let referenceJson = try message.reference.map { reference in
            String(decoding: try Self.encoder.encode(reference), as: UTF8.self)
        }
        try write { db in
            do {
                try db.execute(
                    sql: """
                        INSERT INTO chat_messages
                        (session_id, id, kind, timestamp, text, reference_json, read, decision_status)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        sessionId, message.id, message.kind.rawValue, message.timestamp,
                        message.text, referenceJson, message.read,
                        message.decisionStatus?.rawValue,
                    ])
            } catch let error as DatabaseError where error.message?.contains("UNIQUE constraint failed") == true {
                throw ChronicleError("message ID already exists: \(message.id)")
            }
            for (position, file) in message.files.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO file_references
                        (session_id, message_id, position, path, line, end_line, sha)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [sessionId, message.id, position, file.path, file.line, file.endLine, file.sha])
            }
            try db.execute(
                sql: "UPDATE sessions SET updated_at = ? WHERE id = ?",
                arguments: [ChronicleTimestamp.now(), sessionId])
        }
    }

    @discardableResult
    public func postMessage(
        session: SessionRecord, id: String, kind: MessageKind, text: String,
        reference: DocumentReference? = nil, explicitFiles: [String] = []
    ) throws -> ChatMessage {
        let message = try makeMessage(
            session: session, id: id, kind: kind, text: text,
            reference: reference, explicitFiles: explicitFiles)
        try appendMessage(sessionId: session.id, message: message)
        return message
    }

    public func messages(sessionId: String) throws -> [ChatMessage] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, kind, timestamp, text, reference_json, read, decision_status
                    FROM chat_messages WHERE session_id = ? ORDER BY timestamp, sequence
                    """,
                arguments: [sessionId])
            return try rows.map { row in
                let id: String = row["id"]
                let kindText: String = row["kind"]
                guard let kind = MessageKind(rawValue: kindText) else {
                    throw ChronicleError("database contains invalid message kind: \(kindText)")
                }
                let statusText: String? = row["decision_status"]
                let decisionStatus = try statusText.map { text -> DecisionStatus in
                    guard let status = DecisionStatus(rawValue: text) else {
                        throw ChronicleError("database contains invalid decision status: \(text)")
                    }
                    return status
                }
                let referenceJson: String? = row["reference_json"]
                let reference = try referenceJson.map { json in
                    try JSONDecoder().decode(DocumentReference.self, from: Data(json.utf8))
                }
                let fileRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT path, line, end_line, sha FROM file_references
                        WHERE session_id = ? AND message_id = ? ORDER BY position
                        """,
                    arguments: [sessionId, id])
                return ChatMessage(
                    id: id, kind: kind, timestamp: row["timestamp"], text: row["text"],
                    reference: reference,
                    files: fileRows.map {
                        FileReference(path: $0["path"], line: $0["line"], endLine: $0["end_line"], sha: $0["sha"])
                    },
                    read: row["read"], decisionStatus: decisionStatus)
            }
        }
    }

    public func unlink(sessionId: String, messageId: String) throws {
        try write { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT reference_json FROM chat_messages WHERE session_id = ? AND id = ?",
                arguments: [sessionId, messageId])
            guard let row else {
                throw ChronicleError("message not found: \(messageId)")
            }
            guard row["reference_json"] as String? != nil else {
                throw ChronicleError("message has no document reference: \(messageId)")
            }
            try db.execute(
                sql: "UPDATE chat_messages SET reference_json = NULL WHERE session_id = ? AND id = ?",
                arguments: [sessionId, messageId])
        }
    }

    /// `chronicle read` semantics: one message (never an ack) or all non-ack messages.
    public func markRead(sessionId: String, messageId: String?) throws {
        let changed = try write { db in
            if let messageId {
                return try db.executeWithChanges(
                    sql: """
                        UPDATE chat_messages SET read = 1
                        WHERE session_id = ? AND id = ? AND kind <> 'ack'
                        """,
                    arguments: [sessionId, messageId])
            }
            return try db.executeWithChanges(
                sql: "UPDATE chat_messages SET read = 1 WHERE session_id = ? AND kind <> 'ack'",
                arguments: [sessionId])
        }
        if let messageId, changed == 0 {
            throw ChronicleError("message not found or already read: \(messageId)")
        }
    }

    /// GUI semantics: everything up to and including a message, or everything.
    public func markReadThrough(sessionId: String, messageId: String?) throws {
        try write { db in
            let through: Int64
            if let messageId {
                guard
                    let sequence = try Int64.fetchOne(
                        db,
                        sql: "SELECT sequence FROM chat_messages WHERE session_id = ? AND id = ?",
                        arguments: [sessionId, messageId])
                else {
                    throw ChronicleError("message not found: \(messageId)")
                }
                through = sequence
            } else {
                through = Int64.max
            }
            try db.execute(
                sql: """
                    UPDATE chat_messages SET read = 1
                    WHERE session_id = ? AND sequence <= ? AND kind <> 'ack'
                    """,
                arguments: [sessionId, through])
        }
    }

    public func reviewDecision(sessionId: String, id: String, status: DecisionStatus) throws {
        if status == .unreviewed {
            throw ChronicleError("a decision can only be approved or rejected")
        }
        let timestamp = ChronicleTimestamp.now()
        try write { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT kind, decision_status FROM chat_messages WHERE session_id = ? AND id = ?",
                arguments: [sessionId, id])
            guard let row else {
                throw ChronicleError("decision not found: \(id)")
            }
            guard row["kind"] == "decision" else {
                throw ChronicleError("message is not a decision: \(id)")
            }
            let current: String? = row["decision_status"]
            switch current {
            case "unreviewed":
                try db.execute(
                    sql: "UPDATE chat_messages SET decision_status = ? WHERE session_id = ? AND id = ?",
                    arguments: [status.rawValue, sessionId, id])
                try db.execute(
                    sql: """
                        INSERT INTO decision_reviews (session_id, decision_id, status, reviewed_at)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [sessionId, id, status.rawValue, timestamp])
            case status.rawValue:
                break
            default:
                throw ChronicleError("decision has already been reviewed: \(id)")
            }
            try Self.insertEvent(
                db, sessionId: sessionId,
                event: NormalizedEvent(
                    stableId: "decision-review:\(id)", source: SourceName.chronicle,
                    occurredAt: timestamp, observedAt: timestamp,
                    kind: "decision_\(status.rawValue)",
                    payload: .object(["decisionId": .string(id), "status": .string(status.rawValue)])))
        }
    }

    public func reportStaleReference(
        sessionId: String, messageId: String, locator: DocumentReference
    ) throws {
        try write { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT reference_json FROM chat_messages WHERE session_id = ? AND id = ?",
                arguments: [sessionId, messageId])
            guard let row, let referenceJson: String = row["reference_json"] else {
                throw ChronicleError("message or document reference not found: \(messageId)")
            }
            let stored = try JSONDecoder().decode(DocumentReference.self, from: Data(referenceJson.utf8))
            guard stored == locator else {
                throw ChronicleError("document reference no longer matches message: \(messageId)")
            }
            let timestamp = ChronicleTimestamp.now()
            try Self.insertEvent(
                db, sessionId: sessionId,
                event: NormalizedEvent(
                    stableId: "reference-stale:\(messageId)", source: SourceName.chronicle,
                    occurredAt: timestamp, observedAt: timestamp,
                    kind: "reference_stale",
                    payload: .object([
                        "messageId": .string(messageId),
                        "locator": .object([
                            "heading": .array(locator.heading.map(JSONValue.string)),
                            "snippet": .string(locator.snippet),
                        ]),
                    ])))
        }
    }

    // MARK: - IDE candidates

    public func replaceIDECandidates(sessionId: String, candidates: [IDESessionCandidate]) throws {
        try write { db in
            let selected = try String.fetchOne(
                db,
                sql: "SELECT id FROM ide_candidates WHERE session_id = ? AND selected = 1",
                arguments: [sessionId])
            try db.execute(
                sql: "DELETE FROM ide_candidates WHERE session_id = ?", arguments: [sessionId])
            let auto = candidates.count == 1 ? candidates[0].id : selected
            for candidate in candidates {
                try db.execute(
                    sql: """
                        INSERT INTO ide_candidates (session_id, id, candidate_json, selected)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        sessionId, candidate.id,
                        String(decoding: try Self.encoder.encode(candidate), as: UTF8.self),
                        auto == candidate.id,
                    ])
            }
        }
    }

    public func ideCandidates(sessionId: String) throws -> [IDESessionCandidate] {
        let raw = try read { db in
            try String.fetchAll(
                db, sql: "SELECT candidate_json FROM ide_candidates WHERE session_id = ?",
                arguments: [sessionId])
        }
        return try raw
            .map { try JSONDecoder().decode(IDESessionCandidate.self, from: Data($0.utf8)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func selectedIDECandidate(sessionId: String) throws -> IDESessionCandidate? {
        let raw = try read { db in
            try String.fetchOne(
                db,
                sql: "SELECT candidate_json FROM ide_candidates WHERE session_id = ? AND selected = 1",
                arguments: [sessionId])
        }
        return try raw.map { try JSONDecoder().decode(IDESessionCandidate.self, from: Data($0.utf8)) }
    }

    public func selectIDECandidate(sessionId: String, candidateId: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE ide_candidates SET selected = 0 WHERE session_id = ?",
                arguments: [sessionId])
            let changed = try db.executeWithChanges(
                sql: "UPDATE ide_candidates SET selected = 1 WHERE session_id = ? AND id = ?",
                arguments: [sessionId, candidateId])
            if changed == 0 {
                throw ChronicleError("Chronicle session not found: \(candidateId)")
            }
        }
    }

    // MARK: - Snapshot

    public func snapshot() throws -> AppSnapshot {
        let session = try selectedSession()
        let sessions = try sessionSummaries()
        let ideRoot = try ideRoot()
        let registryFound = FileManager.default.fileExists(
            atPath: ideRoot.appendingPathComponent("sessions.json").path)
        guard let session else {
            let tupleError = try tupleDiscoveryError()
            return AppSnapshot(
                mode: .waitingCall,
                sources: [
                    Self.health(
                        SourceName.tuple, tupleError != nil ? "error" : "waiting",
                        tupleError ?? "Waiting for a Tuple call…"),
                    SourceHealth(source: SourceName.claude, status: .waiting),
                    SourceHealth(source: SourceName.chronicle, status: .off),
                ],
                sessions: sessions,
                ideRoot: ideRoot.path, ideRegistryFound: registryFound,
                integrationInstalled: integrationInstalled())
        }
        let markdown: String
        do {
            markdown = try String(contentsOfFile: session.notesPath, encoding: .utf8)
        } catch {
            throw ChronicleError(
                "cannot read notes document \(session.notesPath): \(error.localizedDescription)")
        }
        let sources = try sourceHealth(sessionId: session.id)
        let tupleStatus = sources.first { $0.source == SourceName.tuple }?.status
        let mode: AppMode
        switch session.state {
        case .active where tupleStatus == "waiting": mode = .waitingTranscription
        case .active where session.repoPath == nil: mode = .waitingClaude
        case .active: mode = .active
        case .finalizing: mode = .finalizing
        case .complete: mode = .complete
        case .interrupted: mode = .interrupted
        }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let handoffSaved =
            !trimmed.isEmpty && session.savedHash == SHA256Hex.hash(Data(markdown.utf8))
        return AppSnapshot(
            mode: mode, sessionId: session.id, sessionState: session.state,
            notesPath: session.notesPath, repoPath: session.repoPath,
            markdown: markdown,
            messages: try messages(sessionId: session.id),
            sources: sources, sessions: sessions,
            ideCandidates: try ideCandidates(sessionId: session.id),
            ideRoot: ideRoot.path, ideRegistryFound: registryFound,
            integrationInstalled: integrationInstalled(),
            handoffSaved: handoffSaved)
    }

    public func sessionSummaries() throws -> [SessionSummary] {
        let rows = try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, state, started_at, updated_at, repo_path, notes_path, saved_hash, data_pruned
                    FROM sessions ORDER BY
                        CASE state WHEN 'active' THEN 0 WHEN 'finalizing' THEN 1 ELSE 2 END,
                        COALESCE(finished_at, updated_at) DESC
                    """)
        }
        return try rows.map { row in
            let stateText: String = row["state"]
            guard let state = SessionState(rawValue: stateText) else {
                throw ChronicleError("database contains invalid session state: \(stateText)")
            }
            let notesPath: String = row["notes_path"]
            let markdown = FileManager.default.contents(atPath: notesPath) ?? Data()
            let savedHash: String? = row["saved_hash"]
            return SessionSummary(
                id: row["id"], state: state,
                startedAt: row["started_at"], updatedAt: row["updated_at"],
                attachedRepo: row["repo_path"],
                hasUnsavedHandoff: !markdown.isEmpty && savedHash != SHA256Hex.hash(markdown),
                dataPruned: row["data_pruned"])
        }
    }

    public func integrationInstalled() -> Bool {
        FileManager.default.fileExists(atPath: paths.shimURL.path)
            && FileManager.default.fileExists(atPath: paths.skillURL.path)
    }

    // MARK: - Export, delete, retention

    public func exportNotes(sessionId: String, destination: String) throws {
        let session = try session(sessionId)
        guard session.state == .complete || session.state == .interrupted else {
            throw ChronicleError("Save As is available after the session ends")
        }
        guard destination.hasPrefix("/") else {
            throw ChronicleError("Save As destination must be an absolute path")
        }
        let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
        if destinationURL.path.hasPrefix(paths.appHome.path + "/") || destinationURL.path == paths.appHome.path {
            throw ChronicleError("Choose a Save As destination outside Chronicle's internal storage")
        }
        let markdown: Data
        do {
            markdown = try Data(contentsOf: URL(fileURLWithPath: session.notesPath))
        } catch {
            throw ChronicleError("cannot read \(session.notesPath): \(error.localizedDescription)")
        }
        let parent = destinationURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ChronicleError("cannot create \(parent.path): \(error.localizedDescription)")
        }
        let temporary = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).chronicle-save-\(UUID().uuidString)")
        do {
            try markdown.write(to: temporary)
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ChronicleError("cannot save \(destinationURL.path): \(error.localizedDescription)")
        }
        try write { db in
            try db.execute(
                sql: """
                    UPDATE sessions SET saved_hash = ?, saved_at = ?, saved_destination = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    SHA256Hex.hash(markdown), ChronicleTimestamp.now(),
                    destinationURL.path, ChronicleTimestamp.now(), sessionId,
                ])
        }
    }

    public func deleteSession(_ sessionId: String) throws {
        let session = try session(sessionId)
        if session.state == .active || session.state == .finalizing {
            throw ChronicleError("active and finalizing sessions cannot be deleted")
        }
        try write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sessionId])
        }
        try removeInternalNotes(session.notesPath)
    }

    public func prune() throws {
        let terminal = try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, notes_path, saved_hash FROM sessions
                    WHERE state IN ('complete', 'interrupted')
                    ORDER BY COALESCE(finished_at, updated_at) DESC, rowid DESC
                    """)
        }
        var remove: [String] = []
        try write { db in
            for (index, row) in terminal.enumerated() where index >= Self.retainedTerminalSessions {
                let id: String = row["id"]
                let notesPath: String = row["notes_path"]
                let savedHash: String? = row["saved_hash"]
                let markdown = FileManager.default.contents(atPath: notesPath) ?? Data()
                let unsaved = !markdown.isEmpty && savedHash != SHA256Hex.hash(markdown)
                if unsaved {
                    for table in [
                        "source_events", "source_state", "consumer_cursors", "decision_reviews",
                        "file_references", "chat_messages", "ide_candidates",
                    ] {
                        try db.execute(
                            sql: "DELETE FROM \(table) WHERE session_id = ?", arguments: [id])
                    }
                    try db.execute(
                        sql: "UPDATE sessions SET data_pruned = 1 WHERE id = ?", arguments: [id])
                } else {
                    try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
                    remove.append(notesPath)
                }
            }
        }
        for notesPath in remove {
            try removeInternalNotes(notesPath)
        }
    }

    private func removeInternalNotes(_ notesPath: String) throws {
        let sessionsRoot = paths.sessionsDirectory.path
        guard notesPath.hasPrefix(sessionsRoot + "/") else {
            throw ChronicleError("refusing to delete non-Chronicle path: \(notesPath)")
        }
        let directory = URL(fileURLWithPath: notesPath).deletingLastPathComponent()
        guard directory.path != sessionsRoot else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // Already gone.
        } catch {
            throw ChronicleError("cannot delete \(directory.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    static func health(_ source: String, _ status: String, _ detail: String?) -> SourceHealth {
        if let known = SourceStatus(rawValue: status) {
            return SourceHealth(source: source, status: known, detail: detail)
        }
        return SourceHealth(source: source, status: status, label: "Off", detail: detail)
    }

    private static func setSetting(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value])
    }

    private static func upsertSourceState(
        _ db: Database, sessionId: String, source: String, status: String,
        detail: String?, cursorJson: String?, timestamp: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO source_state (session_id, source, status, detail, cursor_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, source) DO UPDATE SET
                    status = excluded.status,
                    detail = excluded.detail,
                    cursor_json = COALESCE(excluded.cursor_json, source_state.cursor_json),
                    updated_at = excluded.updated_at
                """,
            arguments: [sessionId, source, status, detail, cursorJson, timestamp])
    }

    @discardableResult
    private static func insertEvent(
        _ db: Database, sessionId: String, event: NormalizedEvent
    ) throws -> Int {
        let payload = String(decoding: try encoder.encode(event.payload), as: UTF8.self)
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO source_events
                (session_id, stable_id, source, stream_id, source_sequence,
                 occurred_at, observed_at, kind, payload_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                sessionId, event.stableId, event.source, event.streamId, event.sourceSequence,
                event.occurredAt, event.observedAt, event.kind, payload,
            ])
        return db.changesCount
    }

    private static func queryCurrentSession(_ db: Database) throws -> SessionRecord? {
        try querySession(
            db,
            where: "state IN ('active', 'finalizing')",
            orderAndLimit: "ORDER BY CASE state WHEN 'active' THEN 0 ELSE 1 END, updated_at DESC LIMIT 1",
            arguments: [])
    }

    private static func querySession(
        _ db: Database, where condition: String,
        orderAndLimit: String = "", arguments: StatementArguments
    ) throws -> SessionRecord? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, state, started_at, repo_path, notes_path, saved_hash
                FROM sessions WHERE \(condition) \(orderAndLimit)
                """,
            arguments: arguments)
        guard let row else { return nil }
        let stateText: String = row["state"]
        guard let state = SessionState(rawValue: stateText) else {
            throw ChronicleError("database contains invalid session state: \(stateText)")
        }
        return SessionRecord(
            id: row["id"], state: state, startedAt: row["started_at"],
            repoPath: row["repo_path"], notesPath: row["notes_path"], savedHash: row["saved_hash"])
    }
}

extension Database {
    fileprivate func executeWithChanges(sql: String, arguments: StatementArguments) throws -> Int {
        try execute(sql: sql, arguments: arguments)
        return changesCount
    }
}
