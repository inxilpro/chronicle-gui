import Foundation
import Testing
@testable import ChronicleKit

@Suite struct IDERegistryTests {
    @Test func fixtureMatchesSchemaOne() throws {
        let candidates = try IDEIngestion.parseRegistry(Fixtures.registry)
        #expect(candidates.count == 1)
        #expect(candidates[0].state == .completed)
        #expect(candidates[0].repositories[0].branch == "main")
        #expect(candidates[0].projectName == "scribe")
    }

    @Test func rejectsUnsupportedSchemaVersion() throws {
        var registry = try JSONSerialization.jsonObject(with: Fixtures.registry) as! [String: Any]
        registry["schemaVersion"] = 2
        let error = captureError {
            _ = try IDEIngestion.parseRegistry(try JSONSerialization.data(withJSONObject: registry))
        }
        #expect(error?.message.contains("schemaVersion") == true)
    }

    @Test func toleratesUnknownRegistryFields() throws {
        var registry = try JSONSerialization.jsonObject(with: Fixtures.registry) as! [String: Any]
        registry["futureTopLevel"] = ["nested": true]
        var sessions = registry["sessions"] as! [[String: Any]]
        sessions[0]["futureSessionField"] = 42
        var ide = sessions[0]["ide"] as! [String: Any]
        ide["build"] = "PS-262.1"
        sessions[0]["ide"] = ide
        var repositories = sessions[0]["repositories"] as! [[String: Any]]
        repositories[0]["upstream"] = "origin"
        sessions[0]["repositories"] = repositories
        registry["sessions"] = sessions
        let candidates = try IDEIngestion.parseRegistry(
            try JSONSerialization.data(withJSONObject: registry))
        #expect(candidates.count == 1)
    }

    @Test func rejectsRegistryContractViolations() throws {
        func mutated(_ update: (inout [String: Any]) -> Void) -> Data {
            var registry = try! JSONSerialization.jsonObject(with: Fixtures.registry) as! [String: Any]
            var sessions = registry["sessions"] as! [[String: Any]]
            update(&sessions[0])
            registry["sessions"] = sessions
            return try! JSONSerialization.data(withJSONObject: registry)
        }
        let cases: [(Data, String)] = [
            (mutated { $0["state"] = "paused" }, "invalid Chronicle session state paused"),
            (mutated { $0["logPath"] = "relative/log.jsonl" }, "logPath must be absolute"),
            (mutated { $0["pid"] = 0 }, "has an invalid pid"),
            (mutated { $0["startedAt"] = "2026-09-01T11:45:00Z" }, "millisecond precision"),
            (
                mutated {
                    $0["state"] = "active"
                    // endedAt stays set from the fixture
                }, "has an endedAt timestamp"
            ),
            (mutated { $0["id"] = " " }, "session id must not be empty"),
            (mutated { $0.removeValue(forKey: "heartbeatAt") }, "heartbeatAt"),
        ]
        for (data, expected) in cases {
            let error = captureError { _ = try IDEIngestion.parseRegistry(data) }
            #expect(error?.message.contains(expected) == true, "expected \(expected), got \(String(describing: error))")
        }

        var registry = try JSONSerialization.jsonObject(with: Fixtures.registry) as! [String: Any]
        var sessions = registry["sessions"] as! [[String: Any]]
        sessions.append(sessions[0])
        registry["sessions"] = sessions
        let duplicate = captureError {
            _ = try IDEIngestion.parseRegistry(try JSONSerialization.data(withJSONObject: registry))
        }
        #expect(duplicate?.message.contains("duplicate Chronicle session id") == true)
    }
}

@Suite struct IDELogTests {
    private let observedAt = "2026-09-01T12:01:00.000Z"

    @Test func fixtureValidatesAllTypesAndSortsByOccurrence() throws {
        let chunk = try IDEIngestion.parseChunk(
            Fixtures.log, candidate: try Fixtures.candidate(),
            previousSequence: 0, previousType: nil, observedAt: observedAt)
        #expect(chunk.events.count == 18)
        #expect(chunk.lastSequence == 18)
        #expect(chunk.lastType == "session_ended")
        #expect(chunk.consumed == Fixtures.log.count)
        let occurred = chunk.events.map(\.occurredAt)
        #expect(occurred == occurred.sorted())
        let shell = try #require(chunk.events.firstIndex { $0.kind == "shell_command" })
        let selection = try #require(chunk.events.firstIndex { $0.kind == "selection" })
        #expect(shell < selection, "late shell history must merge by occurredAt")
        let redacted = chunk.events[selection]
        #expect(redacted.payload["redacted"]?.boolValue == true)
        #expect(redacted.payload["contentTrust"]?.stringValue == "untrusted; read the referenced file")
        #expect(redacted.source == "ide")
        #expect(redacted.streamId == (try Fixtures.candidate().id))
        #expect(redacted.sourceSequence == 9)
        let trusted = try #require(chunk.events.first { $0.kind == "file_opened" })
        #expect(trusted.payload["contentTrust"]?.stringValue == "trusted")
        #expect(trusted.payload["recordedAt"]?.stringValue == "2026-09-01T11:46:00.010Z")
    }

    @Test func toleratesOnlyAnIncompleteFinalLine() throws {
        let firstTwo = Data(Fixtures.logLines[0] + [UInt8(ascii: "\n")] + Fixtures.logLines[1] + [UInt8(ascii: "\n")])
        var truncated = firstTwo
        truncated.append(Data("{\"schemaVersion\":1".utf8))
        let chunk = try IDEIngestion.parseChunk(
            truncated, candidate: try Fixtures.candidate(),
            previousSequence: 0, previousType: nil, observedAt: observedAt)
        #expect(chunk.events.count == 2)
        #expect(chunk.consumed == firstTwo.count)

        var malformedComplete = firstTwo
        malformedComplete.append(Data("not-json\n".utf8))
        let error = captureError {
            _ = try IDEIngestion.parseChunk(
                malformedComplete, candidate: try Fixtures.candidate(),
                previousSequence: 0, previousType: nil, observedAt: observedAt)
        }
        #expect(error?.message.contains("malformed complete") == true)
    }

    @Test func rejectsContractViolations() throws {
        let cases: [(Data, String)] = [
            (Fixtures.mutateLogLine(1) { $0["sequence"] = 3 }, "expected Chronicle sequence 2, found 3"),
            (Fixtures.mutateLogLine(1) { $0["sessionId"] = "wrong" }, "does not match"),
            (Fixtures.mutateLogLine(1) { $0["schemaVersion"] = 2 }, "unsupported event schemaVersion"),
            (
                Fixtures.mutateLogLine(1) { $0["occurredAt"] = "2026-09-01T11:46:00Z" },
                "millisecond precision"
            ),
            (Fixtures.mutateLogLine(1) { $0["redacted"] = false }, "redacted may only be present"),
            (
                Fixtures.mutateLogLine(1) {
                    $0["type"] = "audio_transcription"
                    $0["data"] = ["transcriptionText": "never"]
                }, "audio_transcription is never valid"
            ),
            (
                Fixtures.mutateLogLine(1) {
                    var data = $0["data"] as! [String: Any]
                    data["path"] = "../secret"
                    $0["data"] = data
                }, "escapes projectRoot"
            ),
            (
                Fixtures.mutateLogLine(1) {
                    var data = $0["data"] as! [String: Any]
                    data["path"] = "/Users/chris/Code/scribe/src/App.kt"
                    $0["data"] = data
                }, "must be projectRoot-relative"
            ),
            (
                Fixtures.mutateLogLine(1) { $0["type"] = "telepathy" },
                "unknown Chronicle event type telepathy"
            ),
            (
                Fixtures.mutateLogLine(1) {
                    var data = $0["data"] as! [String: Any]
                    data["mystery"] = true
                    $0["data"] = data
                }, "contains unknown field mystery"
            ),
            (
                Fixtures.mutateLogLine(1) { $0["experimental"] = true },
                "unknown field experimental"
            ),
            (
                Fixtures.mutateLogLine(2) { $0["id"] = "00000000-0000-4000-8000-000000000002" },
                "duplicate Chronicle event id"
            ),
        ]
        for (data, expected) in cases {
            let error = captureError {
                _ = try IDEIngestion.parseChunk(
                    data, candidate: try Fixtures.candidate(),
                    previousSequence: 0, previousType: nil, observedAt: observedAt)
            }
            #expect(
                error?.message.contains(expected) == true,
                "expected \(expected), got \(String(describing: error))")
        }
    }

    @Test func firstSequenceMustBeSessionStarted() throws {
        var withoutFirst = Data(
            Fixtures.logLines.dropFirst().joined(separator: Data("\n".utf8)))
        withoutFirst.append(UInt8(ascii: "\n"))
        let error = captureError {
            _ = try IDEIngestion.parseChunk(
                withoutFirst, candidate: try Fixtures.candidate(),
                previousSequence: 0, previousType: nil, observedAt: observedAt)
        }
        // Sequence 2 arrives where 1 is expected.
        #expect(error?.message.contains("expected Chronicle sequence 1, found 2") == true)

        let wrongFirst = Fixtures.mutateLogLine(0) { $0["type"] = "search"; $0["data"] = ["query": "x"] }
        let firstError = captureError {
            _ = try IDEIngestion.parseChunk(
                wrongFirst, candidate: try Fixtures.candidate(),
                previousSequence: 0, previousType: nil, observedAt: observedAt)
        }
        #expect(firstError?.message == "Chronicle sequence 1 must be session_started")
    }

    @Test func nothingMayFollowSessionEnded() throws {
        var log = Fixtures.log
        log.append(Fixtures.logLines[16])
        log.append(UInt8(ascii: "\n"))
        let error = captureError {
            _ = try IDEIngestion.parseChunk(
                log, candidate: try Fixtures.candidate(),
                previousSequence: 0, previousType: nil, observedAt: observedAt)
        }
        #expect(error?.message == "session_ended is not the final Chronicle record")

        // Also across chunks: a resumed cursor that already saw session_ended.
        let resumed = captureError {
            _ = try IDEIngestion.parseChunk(
                Data(Fixtures.logLines[1] + [UInt8(ascii: "\n")]),
                candidate: try Fixtures.candidate(),
                previousSequence: 18, previousType: "session_ended", observedAt: observedAt)
        }
        #expect(resumed?.message == "session_ended is not the final Chronicle record")
    }

    @Test func emptyLinesAreAnError() throws {
        var log = Data(Fixtures.logLines[0])
        log.append(contentsOf: [UInt8(ascii: "\n"), UInt8(ascii: "\n")])
        let error = captureError {
            _ = try IDEIngestion.parseChunk(
                log, candidate: try Fixtures.candidate(),
                previousSequence: 0, previousType: nil, observedAt: observedAt)
        }
        #expect(error?.message == "empty JSONL record at sequence 2")
    }

    @Test func carriageReturnsAreStripped() throws {
        var log = Data(Fixtures.logLines[0])
        log.append(contentsOf: [UInt8(ascii: "\r"), UInt8(ascii: "\n")])
        let chunk = try IDEIngestion.parseChunk(
            log, candidate: try Fixtures.candidate(),
            previousSequence: 0, previousType: nil, observedAt: observedAt)
        #expect(chunk.events.count == 1)
    }
}

@Suite struct IDEMatchingTests {
    private func candidate(
        id: String, state: IDESessionState, root: String,
        startedAt: String = "2026-09-01T11:45:00.000Z",
        lastEventAt: String = "2026-09-01T12:00:00.000Z",
        endedAt: String? = nil
    ) -> IDESessionCandidate {
        IDESessionCandidate(
            id: id, state: state, logPath: "/logs/\(id).jsonl", projectName: "p",
            projectRoot: root, repositories: [IDERepository(root: root)],
            startedAt: startedAt, lastEventAt: lastEventAt, endedAt: endedAt)
    }

    @Test func matchingChecksEveryRepoThenActiveAndOverlap() throws {
        let home = try TestHome()
        let repo = try makeGitRepository(at: home.scratch("repo"))
        let completed = candidate(
            id: "completed", state: .completed, root: repo, endedAt: "2026-09-01T12:00:00.000Z")
        let active = candidate(id: "active", state: .active, root: repo)
        let matches = IDEIngestion.matchCandidates(
            [completed, active], repo: repo,
            sessionStart: "2026-09-01T11:50:00.000Z", sessionEnd: "2026-09-01T12:10:00.000Z")
        #expect(matches.map(\.id) == ["active"])

        let alsoActive = candidate(id: "also-active", state: .active, root: repo)
        let ambiguous = IDEIngestion.matchCandidates(
            [active, alsoActive], repo: repo,
            sessionStart: "2026-09-01T11:50:00.000Z", sessionEnd: "2026-09-01T12:10:00.000Z")
        #expect(ambiguous.count == 2, "equally good matches must remain ambiguous")

        let elsewhere = candidate(id: "elsewhere", state: .active, root: "/somewhere/else")
        #expect(
            IDEIngestion.matchCandidates(
                [elsewhere], repo: repo,
                sessionStart: "2026-09-01T11:50:00.000Z", sessionEnd: nil
            ).isEmpty)

        // Overlap narrows only when at least one candidate overlaps.
        let old = candidate(
            id: "old", state: .completed, root: repo,
            startedAt: "2026-09-01T09:00:00.000Z", lastEventAt: "2026-09-01T09:30:00.000Z",
            endedAt: "2026-09-01T09:30:00.000Z")
        let overlapping = candidate(
            id: "overlapping", state: .completed, root: repo, endedAt: "2026-09-01T12:00:00.000Z")
        let narrowed = IDEIngestion.matchCandidates(
            [old, overlapping], repo: repo,
            sessionStart: "2026-09-01T11:50:00.000Z", sessionEnd: "2026-09-01T12:10:00.000Z")
        #expect(narrowed.map(\.id) == ["overlapping"])
    }

    @Test func discoveryAutoSelectsSingleCandidateAndFlagsAmbiguity() throws {
        let ideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-ide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ideRoot) }
        let home = try TestHome(environment: ["CHRONICLE_HOME": ideRoot.path])
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let repo = try makeGitRepository(at: home.scratch("repo"))
        let attached = try home.store.attachRepo(sessionId: session.id, repo: repo)

        // No registry yet: off / not detected.
        try IDEIngestion.discover(store: home.store, session: attached)
        #expect(try home.store.sourceHealth(sessionId: session.id)[2].status == "off")

        var registry = try JSONSerialization.jsonObject(with: Fixtures.registry) as! [String: Any]
        var sessions = registry["sessions"] as! [[String: Any]]
        sessions[0]["repositories"] = [["root": repo, "branch": "main"]]
        sessions[0]["state"] = "active"
        sessions[0]["endedAt"] = nil
        sessions[0]["startedAt"] = ChronicleTimestamp.now()
        sessions[0]["lastEventAt"] = ChronicleTimestamp.now()
        registry["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: registry)
            .write(to: ideRoot.appendingPathComponent("sessions.json"))

        try IDEIngestion.discover(store: home.store, session: attached)
        let single = try home.store.sourceHealth(sessionId: session.id)[2]
        #expect(single.status == "live")
        #expect(single.detail == "Chronicle detected")
        #expect(try home.store.selectedIDECandidate(sessionId: session.id) != nil)

        var second = sessions[0]
        second["id"] = "another-session"
        second["logPath"] = "/tmp/another.jsonl"
        sessions.append(second)
        registry["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: registry)
            .write(to: ideRoot.appendingPathComponent("sessions.json"))

        // The earlier auto-selection survives a re-discover even though a
        // second candidate appeared (mirrors scribe).
        try IDEIngestion.discover(store: home.store, session: attached)
        #expect(try home.store.sourceHealth(sessionId: session.id)[2].status == "live")
        #expect(try home.store.ideCandidates(sessionId: session.id).count == 2)

        // A session with no prior selection sees the ambiguity.
        _ = try home.store.createOrResumeSession(callId: "call-2")
        let fresh = try home.store.attachRepo(sessionId: "call-2", repo: repo)
        try IDEIngestion.discover(store: home.store, session: fresh)
        let ambiguous = try home.store.sourceHealth(sessionId: "call-2")[2]
        #expect(ambiguous.status == "ambiguous")
        #expect(ambiguous.detail == "Multiple Chronicle sessions match this repository.")
        #expect(try home.store.ideCandidates(sessionId: "call-2").count == 2)

        // Choosing one via the picker resolves the ambiguity.
        try home.store.selectIDECandidate(sessionId: "call-2", candidateId: "another-session")
        try IDEIngestion.discover(store: home.store, session: fresh)
        #expect(try home.store.sourceHealth(sessionId: "call-2")[2].status == "live")
        #expect(throws: ChronicleError("Chronicle session not found: nope")) {
            try home.store.selectIDECandidate(sessionId: "call-2", candidateId: "nope")
        }
    }

    @Test func discoveryWithoutRepoTurnsSourceOff() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        try IDEIngestion.discover(store: home.store, session: session)
        let health = try home.store.sourceHealth(sessionId: session.id)[2]
        #expect(health.status == "off")
        #expect(health.detail == "Attach a repository to discover Chronicle.")
    }
}

@Suite struct IDETailTests {
    private func activeFixtureCandidate(logPath: String) throws -> IDESessionCandidate {
        var candidate = try Fixtures.candidate()
        candidate.state = .active
        candidate.endedAt = nil
        candidate.logPath = logPath
        return candidate
    }

    @Test func tailRecoversReplacementWithoutDuplicateImports() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let log = home.scratch("chronicle.jsonl")
        let lines = Fixtures.logLines
        func write(_ count: Int, to url: URL) throws {
            var data = Data(lines.prefix(count).joined(separator: Data("\n".utf8)))
            data.append(UInt8(ascii: "\n"))
            try data.write(to: url)
        }
        try write(2, to: log)
        let candidate = try activeFixtureCandidate(logPath: log.path)
        try home.store.replaceIDECandidates(sessionId: session.id, candidates: [candidate])
        try IDEIngestion.collect(store: home.store, session: session)
        #expect(try home.store.show(sessionId: session.id, consumer: "first", limit: 10).events.count == 2)

        // Atomic replacement with one more record: a new inode resets the
        // cursor, and the stream index deduplicates the re-read.
        let replacement = home.scratch("replacement.jsonl")
        try write(3, to: replacement)
        _ = try FileManager.default.replaceItemAt(log, withItemAt: replacement)
        try IDEIngestion.collect(store: home.store, session: session)
        let delivered = try home.store.show(sessionId: session.id, consumer: "first", limit: 10)
        #expect(delivered.events.count == 1)
        #expect(delivered.events[0].sourceSequence == 3)
    }

    @Test func partialTailIsDeferredUntilTheLineCompletes() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let log = home.scratch("chronicle.jsonl")
        let lines = Fixtures.logLines
        var data = Data(lines[0])
        data.append(UInt8(ascii: "\n"))
        let partial = lines[1].prefix(40)
        data.append(contentsOf: partial)
        try data.write(to: log)
        let candidate = try activeFixtureCandidate(logPath: log.path)
        try home.store.replaceIDECandidates(sessionId: session.id, candidates: [candidate])
        try IDEIngestion.collect(store: home.store, session: session)
        #expect(try home.store.show(sessionId: session.id, consumer: "c", limit: 10).events.count == 1)

        var rest = Data(lines[1].dropFirst(40))
        rest.append(UInt8(ascii: "\n"))
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: rest)
        try handle.close()
        try IDEIngestion.collect(store: home.store, session: session)
        let next = try home.store.show(sessionId: session.id, consumer: "c", limit: 10)
        #expect(next.events.count == 1)
        #expect(next.events[0].sourceSequence == 2)
    }

    @Test func validationFailurePreservesTheCursorAndSetsError() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let log = home.scratch("chronicle.jsonl")
        var good = Data(Fixtures.logLines[0])
        good.append(UInt8(ascii: "\n"))
        try good.write(to: log)
        let candidate = try activeFixtureCandidate(logPath: log.path)
        try home.store.replaceIDECandidates(sessionId: session.id, candidates: [candidate])
        try IDEIngestion.collect(store: home.store, session: session)
        let cursorBefore = try #require(
            try home.store.sourceState(sessionId: session.id, source: "chronicle")?.cursorJson)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        let error = captureError { try IDEIngestion.collect(store: home.store, session: session) }
        #expect(error?.message.contains("Invalid Chronicle log") == true)
        let state = try #require(try home.store.sourceState(sessionId: session.id, source: "chronicle"))
        #expect(state.status == "error")
        #expect(state.cursorJson == cursorBefore)
    }

    @Test func completedRegistryStateRequiresSessionEndedLog() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let log = home.scratch("chronicle.jsonl")
        var data = Data(Fixtures.logLines.prefix(2).joined(separator: Data("\n".utf8)))
        data.append(UInt8(ascii: "\n"))
        try data.write(to: log)
        var candidate = try Fixtures.candidate()
        candidate.logPath = log.path
        try home.store.replaceIDECandidates(sessionId: session.id, candidates: [candidate])
        let error = captureError { try IDEIngestion.collect(store: home.store, session: session) }
        #expect(
            error?.message
                == "Chronicle marks \(candidate.id) completed, but its log does not end with session_ended")
    }

    @Test func missingLogIsStoppedNotFatal() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-1")
        let candidate = try activeFixtureCandidate(logPath: home.scratch("missing.jsonl").path)
        try home.store.replaceIDECandidates(sessionId: session.id, candidates: [candidate])
        try IDEIngestion.collect(store: home.store, session: session)
        let health = try home.store.sourceHealth(sessionId: session.id)[2]
        #expect(health.status == "stopped")
        #expect(health.detail == "Chronicle log is not available.")
    }
}
