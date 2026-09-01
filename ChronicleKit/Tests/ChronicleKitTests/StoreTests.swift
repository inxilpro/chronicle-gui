import Foundation
import GRDB
import Testing
@testable import ChronicleKit

@Suite struct StoreTests {
    @Test func migratesDatabaseAndEnablesWAL() throws {
        let home = try TestHome()
        let (journalMode, foreignKeys) = try home.store.databaseReader.read { db in
            (
                try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
            )
        }
        #expect(journalMode == "wal")
        #expect(foreignKeys)
    }

    @Test func cursorDeliveryIsDurableOrderedAndDeduplicated() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let late = makeEvent("late", occurredAt: "2026-09-01T12:00:03.000Z")
        let early = makeEvent("early", occurredAt: "2026-09-01T12:00:01.000Z")
        #expect(try home.store.insertSourceEvents(sessionId: session.id, events: [late, late]) == 1)
        #expect(try home.store.insertSourceEvents(sessionId: session.id, events: [early, early]) == 1)

        let first = try home.store.show(sessionId: session.id, consumer: "chronicle", limit: 1)
        #expect(first.events.map(\.stableId) == ["early"])
        #expect(first.hasMore)
        let second = try home.store.show(sessionId: session.id, consumer: "chronicle", limit: 10)
        #expect(second.events.map(\.stableId) == ["late"])
        #expect(!second.hasMore)
        #expect(try home.store.show(sessionId: session.id, consumer: "chronicle", limit: 10).events.isEmpty)

        // A source record that arrives late is still delivered exactly once on
        // the next show with its original occurrence timestamp.
        let veryEarly = makeEvent("very-early", occurredAt: "2026-09-01T11:59:00.000Z")
        try home.store.insertSourceEvents(sessionId: session.id, events: [veryEarly])
        let third = try home.store.show(sessionId: session.id, consumer: "chronicle", limit: 10)
        #expect(third.events.map(\.stableId) == ["very-early"])
    }

    @Test func concurrentShowsForOneConsumerSplitEvents() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        try home.store.insertSourceEvents(
            sessionId: session.id,
            events: [
                makeEvent("first", occurredAt: "2026-09-01T12:00:01.000Z"),
                makeEvent("second", occurredAt: "2026-09-01T12:00:02.000Z"),
            ])
        let stores = [home.store, try home.reopenStore()]
        nonisolated(unsafe) var delivered: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = try? stores[index].show(sessionId: "call-1", consumer: "chronicle", limit: 1)
            lock.lock()
            delivered.append(contentsOf: (result?.events ?? []).map(\.stableId))
            lock.unlock()
        }
        #expect(delivered.sorted() == ["first", "second"])
    }

    @Test func concurrentConnectionsDoNotLoseMessages() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let repo = try makeGitRepository(at: home.scratch("repo"))
        _ = try home.store.attachRepo(sessionId: session.id, repo: repo)
        let store = home.store
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let message = ChatMessage(
                id: "message-\(index)", kind: .message,
                timestamp: String(format: "2026-09-01T12:00:%02d.000Z", index),
                text: "message \(index)")
            try? store.appendMessage(sessionId: "call-1", message: message)
        }
        #expect(try home.store.messages(sessionId: session.id).count == 8)
    }

    @Test func lifecycleRequiresCallEndBeforeFinish() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        #expect(throws: ChronicleError("Tuple call is still active; finish after Chronicle reports finalizing")) {
            try home.store.finishSession(session.id)
        }
        try home.store.markCallEnded(session.id)
        #expect(try home.store.session(session.id).state == .finalizing)
        try home.store.finishSession(session.id)
        #expect(try home.store.session(session.id).state == .complete)
        #expect(throws: ChronicleError("session is already complete")) {
            try home.store.finishSession(session.id)
        }

        let interrupted = try home.store.createOrResumeSession(callId: "call-2")
        _ = try home.store.createOrResumeSession(callId: "call-3")
        #expect(try home.store.session(interrupted.id).state == .interrupted)
        #expect(throws: ChronicleError("an interrupted session cannot be finished")) {
            try home.store.finishSession(interrupted.id)
        }
    }

    @Test func staleActiveSessionBecomesInterrupted() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "stale-call")
        try (home.store.databaseReader as! DatabaseWriter).write { db in
            try db.execute(
                sql: "UPDATE sessions SET updated_at = '2020-01-01T00:00:00.000Z' WHERE id = ?",
                arguments: [session.id])
        }
        #expect(try home.store.interruptStaleSessions(olderThan: 12 * 3600) == 1)
        #expect(try home.store.session("stale-call").state == .interrupted)
    }

    @Test func saveHashDetectsEditsAndDeleteNeverRemovesExport() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "saved-call")
        try "# Ready\n".write(toFile: session.notesPath, atomically: true, encoding: .utf8)
        try home.store.markCallEnded(session.id)
        try home.store.finishSession(session.id)

        #expect(throws: ChronicleError.self) {
            try home.store.exportNotes(
                sessionId: session.id,
                destination: home.paths.appHome.appendingPathComponent("plan.md").path)
        }
        let destination = home.scratch("export/plan.md")
        try home.store.exportNotes(sessionId: session.id, destination: destination.path)
        #expect(try home.store.snapshot().handoffSaved)

        try "# Ready\n\nOne more detail.\n".write(toFile: session.notesPath, atomically: true, encoding: .utf8)
        #expect(try !home.store.snapshot().handoffSaved)
        try home.store.deleteSession(session.id)
        #expect(!FileManager.default.fileExists(atPath: session.notesPath))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "# Ready\n")
    }

    @Test func exportRequiresTerminalStateAndAbsolutePath() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        #expect(throws: ChronicleError("Save As is available after the session ends")) {
            try home.store.exportNotes(sessionId: session.id, destination: home.scratch("plan.md").path)
        }
        try home.store.markCallEnded(session.id)
        try home.store.finishSession(session.id)
        #expect(throws: ChronicleError("Save As destination must be an absolute path")) {
            try home.store.exportNotes(sessionId: session.id, destination: "relative/plan.md")
        }
        #expect(throws: ChronicleError("Choose a Save As destination outside Chronicle's internal storage")) {
            try home.store.exportNotes(
                sessionId: session.id,
                destination: home.paths.appHome.appendingPathComponent("inside.md").path)
        }
    }

    @Test func relaunchReturnsToWaitingWhileHistoryRemains() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "previous-call")
        try home.store.markCallEnded(session.id)
        try home.store.finishSession(session.id)
        #expect(try home.store.snapshot().sessionId == "previous-call")

        try home.store.clearTerminalSelectionForLaunch()
        let relaunched = try home.store.snapshot()
        #expect(relaunched.mode == .waitingCall)
        #expect(relaunched.sessionId == nil)
        #expect(relaunched.sessions.count == 1)
    }

    @Test func retentionKeepsFiveFullSessionsAndProtectsUnsavedHandoffs() throws {
        let home = try TestHome()
        for index in 0..<7 {
            let id = "call-\(index)"
            let session = try home.store.createOrResumeSession(callId: id)
            try "# Plan \(index)\n".write(toFile: session.notesPath, atomically: true, encoding: .utf8)
            try home.store.insertSourceEvents(
                sessionId: id,
                events: [makeEvent("event-\(index)", occurredAt: "2026-09-01T12:00:00.000Z")])
            try home.store.markCallEnded(id)
            try home.store.finishSession(id)
        }
        let summaries = try home.store.sessionSummaries()
        #expect(summaries.count == 7)
        #expect(summaries.filter(\.dataPruned).count == 2)
        let oldest = try home.store.session("call-0")
        #expect(FileManager.default.fileExists(atPath: oldest.notesPath))
        // Once pruned, show returns empty forever.
        #expect(try home.store.show(sessionId: "call-0", consumer: "debug", limit: 10).events.isEmpty)
    }

    @Test func retentionDeletesSavedSessionsEntirely() throws {
        let home = try TestHome()
        var notesPaths: [String] = []
        for index in 0..<7 {
            let id = "call-\(index)"
            let session = try home.store.createOrResumeSession(callId: id)
            try "# Plan \(index)\n".write(toFile: session.notesPath, atomically: true, encoding: .utf8)
            try home.store.markCallEnded(id)
            try home.store.finishSession(id)
            try home.store.exportNotes(
                sessionId: id, destination: home.scratch("exports/plan-\(index).md").path)
            notesPaths.append(session.notesPath)
        }
        try home.store.prune()
        let summaries = try home.store.sessionSummaries()
        #expect(summaries.count == 5)
        #expect(!FileManager.default.fileExists(atPath: notesPaths[0]))
        #expect(!FileManager.default.fileExists(atPath: notesPaths[1]))
        #expect(FileManager.default.fileExists(atPath: home.scratch("exports/plan-0.md").path))
    }

    @Test func createOrResumeDemotesOtherActiveAndResumesInterrupted() throws {
        let home = try TestHome()
        _ = try home.store.createOrResumeSession(callId: "call-a")
        _ = try home.store.createOrResumeSession(callId: "call-b")
        #expect(try home.store.session("call-a").state == .interrupted)
        let resumed = try home.store.createOrResumeSession(callId: "call-a")
        #expect(resumed.state == .active)
        #expect(try home.store.session("call-b").state == .interrupted)
        #expect(throws: ChronicleError("Tuple returned an empty call ID")) {
            _ = try home.store.createOrResumeSession(callId: "   ")
        }
    }

    @Test func decisionReviewIsIdempotentAndInjectsSyntheticEvent() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let repo = try makeGitRepository(at: home.scratch("repo"))
        let attached = try home.store.attachRepo(sessionId: session.id, repo: repo)
        try home.store.postMessage(session: attached, id: "adr-1", kind: .decision, text: "Ship it")

        try home.store.reviewDecision(sessionId: session.id, id: "adr-1", status: .approved)
        try home.store.reviewDecision(sessionId: session.id, id: "adr-1", status: .approved)
        #expect(throws: ChronicleError("decision has already been reviewed: adr-1")) {
            try home.store.reviewDecision(sessionId: session.id, id: "adr-1", status: .rejected)
        }
        #expect(throws: ChronicleError("a decision can only be approved or rejected")) {
            try home.store.reviewDecision(sessionId: session.id, id: "adr-1", status: .unreviewed)
        }
        let result = try home.store.show(sessionId: session.id, consumer: "chronicle", limit: 10)
        let reviews = result.events.filter { $0.kind == "decision_approved" }
        #expect(reviews.count == 1)
        #expect(reviews[0].stableId == "decision-review:adr-1")
        #expect(reviews[0].source == "chronicle")
        #expect(reviews[0].payload["decisionId"]?.stringValue == "adr-1")
        #expect(try home.store.messages(sessionId: session.id)[0].decisionStatus == .approved)

        try home.store.postMessage(session: attached, id: "msg", kind: .message, text: "hello")
        #expect(throws: ChronicleError("message is not a decision: msg")) {
            try home.store.reviewDecision(sessionId: session.id, id: "msg", status: .approved)
        }
        #expect(throws: ChronicleError("decision not found: nope")) {
            try home.store.reviewDecision(sessionId: session.id, id: "nope", status: .approved)
        }
    }

    @Test func staleReferenceReportVerifiesAndDedupes() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let repo = try makeGitRepository(at: home.scratch("repo"))
        let attached = try home.store.attachRepo(sessionId: session.id, repo: repo)
        let reference = DocumentReference(heading: ["Plan"], snippet: "the snippet")
        try home.store.postMessage(
            session: attached, id: "m1", kind: .message, text: "see plan", reference: reference)

        let wrong = DocumentReference(heading: ["Plan"], snippet: "different")
        #expect(throws: ChronicleError("document reference no longer matches message: m1")) {
            try home.store.reportStaleReference(sessionId: session.id, messageId: "m1", locator: wrong)
        }
        #expect(throws: ChronicleError("message or document reference not found: missing")) {
            try home.store.reportStaleReference(
                sessionId: session.id, messageId: "missing", locator: reference)
        }
        try home.store.reportStaleReference(sessionId: session.id, messageId: "m1", locator: reference)
        try home.store.reportStaleReference(sessionId: session.id, messageId: "m1", locator: reference)
        let result = try home.store.show(sessionId: session.id, consumer: "chronicle", limit: 10)
        let stale = result.events.filter { $0.kind == "reference_stale" }
        #expect(stale.count == 1)
        #expect(stale[0].payload["locator"]?["snippet"]?.stringValue == "the snippet")
    }

    @Test func unlinkAndReadValidateTheirTargets() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let repo = try makeGitRepository(at: home.scratch("repo"))
        let attached = try home.store.attachRepo(sessionId: session.id, repo: repo)
        try home.store.postMessage(
            session: attached, id: "linked", kind: .message, text: "text",
            reference: DocumentReference(heading: ["A"], snippet: "s"))
        try home.store.postMessage(session: attached, id: "plain", kind: .message, text: "text")
        try home.store.postMessage(session: attached, id: "quiet", kind: .ack, text: "ok")

        #expect(throws: ChronicleError("message not found: missing")) {
            try home.store.unlink(sessionId: session.id, messageId: "missing")
        }
        #expect(throws: ChronicleError("message has no document reference: plain")) {
            try home.store.unlink(sessionId: session.id, messageId: "plain")
        }
        try home.store.unlink(sessionId: session.id, messageId: "linked")
        #expect(try home.store.messages(sessionId: session.id).first { $0.id == "linked" }?.reference == nil)

        #expect(throws: ChronicleError("message not found or already read: quiet")) {
            try home.store.markRead(sessionId: session.id, messageId: "quiet")
        }
        try home.store.markRead(sessionId: session.id, messageId: "plain")
        try home.store.markRead(sessionId: session.id, messageId: nil)
        let messages = try home.store.messages(sessionId: session.id)
        #expect(messages.first { $0.id == "plain" }?.read == true)
        // Acks are born read and ignored by read-marking.
        #expect(messages.first { $0.id == "quiet" }?.read == true)
    }

    @Test func postingRequiresAttachedRepositoryAndUniqueIds() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        #expect(throws: ChronicleError("the chronicle skill has not attached a repository")) {
            try home.store.postMessage(session: session, id: "x", kind: .message, text: "hello")
        }
        let repo = try makeGitRepository(at: home.scratch("repo"))
        let attached = try home.store.attachRepo(sessionId: session.id, repo: repo)
        #expect(throws: ChronicleError("message text cannot be empty")) {
            try home.store.postMessage(session: attached, id: "x", kind: .message, text: "  ")
        }
        try home.store.postMessage(session: attached, id: "dup", kind: .decision, text: "one")
        #expect(throws: ChronicleError("message ID already exists: dup")) {
            try home.store.postMessage(session: attached, id: "dup", kind: .decision, text: "two")
        }
    }

    @Test func fileReferencesAreParsedInferredAndStamped() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let repo = try makeGitRepository(at: home.scratch("repo"))
        let attached = try home.store.attachRepo(sessionId: session.id, repo: repo)
        let head = try GitClient.headSHA(repository: repo)
        let message = try home.store.postMessage(
            session: attached, id: "m1", kind: .message,
            text: "See `app/Jobs/Sync.php:14-20` and `docs/notes.md`",
            explicitFiles: ["app/Jobs/Sync.php:14-20", "src/other.rs:3"])
        #expect(message.files.map(\.path) == ["app/Jobs/Sync.php", "src/other.rs", "docs/notes.md"])
        #expect(message.files[0].line == 14)
        #expect(message.files[0].endLine == 20)
        #expect(message.files.allSatisfy { $0.sha == head })
    }

    @Test func snapshotDerivesModes() throws {
        let home = try TestHome()
        #expect(try home.store.snapshot().mode == .waitingCall)

        let session = try home.store.createOrResumeSession(callId: "call-1")
        #expect(try home.store.snapshot().mode == .waitingTranscription)

        try home.store.setSourceState(
            sessionId: session.id, source: "tuple", status: "live", detail: "Transcription is live.")
        #expect(try home.store.snapshot().mode == .waitingClaude)

        let repo = try makeGitRepository(at: home.scratch("repo"))
        _ = try home.store.attachRepo(sessionId: session.id, repo: repo)
        #expect(try home.store.snapshot().mode == .active)
        let health = try home.store.sourceHealth(sessionId: session.id)
        #expect(health.map(\.source) == ["tuple", "claude", "chronicle"])
        #expect(health[1].status == "connected")
        #expect(health[1].detail == "chronicle skill attached")
        #expect(health[2].status == "off")

        try home.store.markCallEnded(session.id)
        #expect(try home.store.snapshot().mode == .finalizing)
        try home.store.finishSession(session.id)
        #expect(try home.store.snapshot().mode == .complete)
    }

    @Test func tupleDiscoveryErrorSurfacesOnWaitingScreen() throws {
        let home = try TestHome()
        try home.store.setTupleDiscoveryError("Tuple CLI was not found at /nope. Install CLI.")
        let snapshot = try home.store.snapshot()
        #expect(snapshot.sources[0].status == "error")
        #expect(snapshot.sources[0].detail?.contains("Install CLI") == true)
        try home.store.setTupleDiscoveryError(nil)
        #expect(try home.store.snapshot().sources[0].status == "waiting")
    }

    @Test func showValidatesConsumerAndLimit() throws {
        let home = try TestHome()
        _ = try home.store.createOrResumeSession(callId: "call-1")
        #expect(throws: ChronicleError("cursor name must be non-empty and contain no whitespace")) {
            _ = try home.store.show(sessionId: "call-1", consumer: "bad name", limit: 10)
        }
        #expect(throws: ChronicleError("show limit must be between 1 and 10000")) {
            _ = try home.store.show(sessionId: "call-1", consumer: "ok", limit: 0)
        }
        #expect(throws: ChronicleError("show limit must be between 1 and 10000")) {
            _ = try home.store.show(sessionId: "call-1", consumer: "ok", limit: 10_001)
        }
    }

    @Test func streamUniqueIndexDeduplicatesBySequence() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        var first = makeEvent("ide-1", occurredAt: "2026-09-01T12:00:01.000Z")
        first.source = "ide"
        first.streamId = "stream"
        first.sourceSequence = 1
        var duplicate = first
        duplicate.stableId = "ide-1-renamed"
        #expect(try home.store.insertSourceEvents(sessionId: session.id, events: [first]) == 1)
        #expect(try home.store.insertSourceEvents(sessionId: session.id, events: [duplicate]) == 0)
    }
}

@Suite struct FileSpecTests {
    @Test func parsesFileLinesAndRanges() throws {
        #expect(
            try FileSpec.parse("app/Jobs/Sync.php:14-20")
                == FileSpec(path: "app/Jobs/Sync.php", line: 14, endLine: 20))
        #expect(try FileSpec.parse("./src/main.rs:7") == FileSpec(path: "src/main.rs", line: 7))
        #expect(try FileSpec.parse("plain/path") == FileSpec(path: "plain/path"))
        #expect(throws: ChronicleError("file references must be repository-relative paths: ../outside.php:2")) {
            _ = try FileSpec.parse("../outside.php:2")
        }
        #expect(throws: ChronicleError("file reference has a backwards line range: app/Foo.php:20-14")) {
            _ = try FileSpec.parse("app/Foo.php:20-14")
        }
        #expect(throws: ChronicleError("line numbers start at 1: app/Foo.php:0")) {
            _ = try FileSpec.parse("app/Foo.php:0")
        }
        #expect(throws: ChronicleError.self) { _ = try FileSpec.parse("https://example.com/x") }
        #expect(throws: ChronicleError.self) { _ = try FileSpec.parse("/absolute/path.php") }
    }

    @Test func infersBacktickedPathsFromText() {
        let specs = FileSpec.inferred(
            from: "Look at `src/a.rs:4` and `not a path` plus `src/a.rs:4` again and `b.txt`")
        #expect(specs == [FileSpec(path: "src/a.rs", line: 4)])
    }
}

@Suite struct TimestampNormalizationTests {
    @Test func speechTimestampAcceptsEpochSeconds() {
        #expect(
            TupleRecordParser.normalizeTimestamp(
                .number(1_788_264_000.125), fallback: "2026-09-01T12:00:01.000Z")
                == "2026-09-01T12:00:00.125Z")
    }

    @Test func acceptsEpochMillisAndNumericStrings() {
        #expect(
            TupleRecordParser.normalizeTimestamp(
                .number(1_788_264_000_125), fallback: "fallback")
                == "2026-09-01T12:00:00.125Z")
        #expect(
            TupleRecordParser.normalizeTimestamp(
                .string("1788264000"), fallback: "fallback")
                == "2026-09-01T12:00:00.000Z")
    }

    @Test func normalizesOffsetsToUTCMillis() {
        #expect(
            TupleRecordParser.normalizeTimestamp(
                .string("2026-09-01T14:00:09+02:00"), fallback: "fallback")
                == "2026-09-01T12:00:09.000Z")
        #expect(
            TupleRecordParser.normalizeTimestamp(.null, fallback: "fallback") == "fallback")
        #expect(
            TupleRecordParser.normalizeTimestamp(
                .string("not a time"), fallback: "fallback") == "fallback")
    }
}
