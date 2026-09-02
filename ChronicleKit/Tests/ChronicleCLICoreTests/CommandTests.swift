import Foundation
import Testing
import ChronicleKit
@testable import ChronicleCLICore

private struct FakeTuple: TupleCalling {
    var callId: String?

    func currentCall() throws -> String? { callId }
    func collect(store: ChronicleStore, session: SessionRecord, timeout: String) throws {}
}

private final class CLITestHome {
    let root: URL
    let store: ChronicleStore
    let repo: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var paths = ChroniclePaths(appHome: root.appendingPathComponent("app-home", isDirectory: true))
        paths.shimURL = root.appendingPathComponent("bin/chronicle")
        paths.skillURL = root.appendingPathComponent("skills/chronicle/SKILL.md")
        store = try ChronicleStore(paths: paths, environment: [:])

        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Chronicle Tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "initial"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = repoURL
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        repo = repoURL.path
    }

    func context(callId: String? = "tuple-call-1") -> CLIContext {
        nonisolated(unsafe) var counter = 0
        return CLIContext(
            store: store, tuple: FakeTuple(callId: callId),
            makeMessageId: {
                counter += 1
                return "generated-\(counter)"
            })
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func run(_ arguments: [String], context: CLIContext) throws -> String {
    try ChronicleCLIRunner.run(arguments, context: context)
}

private func runError(_ arguments: [String], context: CLIContext) -> ChronicleError? {
    do {
        _ = try run(arguments, context: context)
        return nil
    } catch {
        return error as? ChronicleError
    }
}

private func json(_ text: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}

@Suite struct CommandConfigurationTests {
    @Test func commandIsNamedChronicle() {
        #expect(ChronicleCommand.configuration.commandName == "chronicle")
    }

    @Test func validatesTimeoutGrammarAndBounds() {
        #expect(try! validateTimeout("30s") == 30_000)
        #expect(try! validateTimeout("500ms") == 500)
        #expect(try! validateTimeout("5m") == 300_000)
        #expect(try! validateTimeout("1ms") == 1)
        #expect(throws: ChronicleError("--timeout must be between 1ms and 5m")) {
            _ = try validateTimeout("0s")
        }
        #expect(throws: ChronicleError("--timeout must be between 1ms and 5m")) {
            _ = try validateTimeout("6m")
        }
        #expect(throws: ChronicleError("--timeout must start with an integer")) {
            _ = try validateTimeout("soon")
        }
        #expect(throws: ChronicleError("--timeout must include ms, s, or m")) {
            _ = try validateTimeout("300")
        }
        #expect(throws: ChronicleError("--timeout must use ms, s, or m")) {
            _ = try validateTimeout("30h")
        }
    }
}

@Suite struct SessionAndShowCommandTests {
    @Test func sessionAndShowContractsAreMachineReadable() throws {
        let home = try CLITestHome()
        let context = home.context()
        let attach = try json(
            try run(["session", "attach", "--repo", home.repo], context: context))
        #expect(attach["sessionId"] as? String == "tuple-call-1")
        #expect((attach["notesPath"] as? String)?.hasSuffix("notes.md") == true)
        #expect(attach["state"] as? String == "active")
        let health = try #require(attach["sourceHealth"] as? [[String: Any]])
        #expect(health.map { $0["source"] as? String } == ["tuple", "claude", "chronicle"])
        #expect(health[1]["status"] as? String == "connected")

        try home.store.insertSourceEvents(
            sessionId: "tuple-call-1",
            events: [
                NormalizedEvent(
                    stableId: "speech-1", source: "tuple",
                    occurredAt: "2026-09-01T12:00:00.000Z", observedAt: ChronicleTimestamp.now(),
                    kind: "speech", payload: .object(["text": .string("hello")]))
            ])
        let show = try json(
            try run(["show", "--cursor", "chronicle", "--limit", "10"], context: context))
        let events = try #require(show["events"] as? [[String: Any]])
        #expect(events.first?["stableId"] as? String == "speech-1")
        #expect(show["notesPath"] as? String == attach["notesPath"] as? String)
        #expect(show["hasMore"] as? Bool == false)

        let current = try json(try run(["session", "current", "--json"], context: context))
        #expect(current["sessionId"] as? String == "tuple-call-1")
    }

    @Test func showWaitReturnsAsSoonAsEventsExist() throws {
        let home = try CLITestHome()
        let context = home.context()
        _ = try run(["session", "attach", "--repo", home.repo], context: context)
        try home.store.insertSourceEvents(
            sessionId: "tuple-call-1",
            events: [
                NormalizedEvent(
                    stableId: "e1", source: "tuple",
                    occurredAt: "2026-09-01T12:00:00.000Z", observedAt: ChronicleTimestamp.now(),
                    kind: "speech", payload: .object(["text": .string("hi")]))
            ])
        let started = Date()
        let show = try json(
            try run(
                ["show", "--wait", "--cursor", "chronicle", "--timeout", "5s"], context: context))
        #expect((show["events"] as? [[String: Any]])?.count == 1)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func showValidatesItsOptions() throws {
        let home = try CLITestHome()
        let context = home.context()
        #expect(runError(["show"], context: context)?.message == "show requires --cursor <name>")
        #expect(
            runError(["show", "--cursor", "c", "--limit", "abc"], context: context)?.message
                == "--limit must be an integer")
        #expect(
            runError(["show", "--cursor", "c", "--timeout", "10h"], context: context)?.message
                == "--timeout must use ms, s, or m")
        _ = try run(["session", "attach", "--repo", home.repo], context: context)
        #expect(
            runError(["show", "--cursor", "bad name"], context: context)?.message
                == "cursor name must be non-empty and contain no whitespace")
        #expect(
            runError(["show", "--cursor", "c", "--limit", "0"], context: context)?.message
                == "show limit must be between 1 and 10000")
    }

    @Test func sessionCommandsValidateUsageAndState() throws {
        let home = try CLITestHome()
        let noCall = home.context(callId: nil)
        #expect(
            runError(["session", "current"], context: noCall)?.message
                == "usage: chronicle session current --json")
        #expect(
            runError(["session", "current", "--json"], context: noCall)?.message
                == "no active or finalizing Chronicle session; join a Tuple call first")
        #expect(
            runError(["session", "attach"], context: noCall)?.message
                == "usage: chronicle session attach --repo <path>")
        #expect(
            runError(["say", "hello"], context: noCall)?.message
                == "no active Chronicle session; join a Tuple call and open Chronicle first")
        #expect(
            runError(["session", "finish"], context: noCall)?.message
                == "no active or finalizing Chronicle session to finish")
        #expect(
            runError(["session"], context: noCall)?.message
                == "session requires attach, current, or finish")

        // With a call available the session resolves first, then git validation runs.
        let withCall = home.context()
        #expect(
            runError(["session", "attach", "--repo", "/nonexistent-path"], context: withCall)?.message
                == "/nonexistent-path is not inside a Git repository")
    }

    @Test func sessionFinishCompletesAFinalizingSession() throws {
        let home = try CLITestHome()
        let context = home.context()
        _ = try run(["session", "attach", "--repo", home.repo], context: context)
        #expect(
            runError(["session", "finish"], context: context)?.message
                == "Tuple call is still active; finish after Chronicle reports finalizing. If the call has already ended, choose Session > End Session in the Chronicle app, then finish.")
        try home.store.markCallEnded("tuple-call-1")
        let output = try run(["session", "finish"], context: context)
        #expect(output == "{\"sessionId\":\"tuple-call-1\",\"state\":\"complete\"}")
    }
}

@Suite struct WorkingCommandTests {
    @Test func workingSignalsAndTheNextFeedItemClearsIt() throws {
        let home = try CLITestHome()
        let context = home.context()
        _ = try run(["session", "attach", "--repo", home.repo], context: context)
        #expect(try run(["working"], context: context) == "working")
        #expect(try home.store.agentWorkingSince(sessionId: "tuple-call-1") != nil)
        _ = try run(["say", "found it"], context: context)
        #expect(try home.store.agentWorkingSince(sessionId: "tuple-call-1") == nil)
    }

    @Test func workingRequiresASession() throws {
        let home = try CLITestHome()
        #expect(
            runError(["working"], context: home.context(callId: nil))?.message
                == "no active Chronicle session; join a Tuple call and open Chronicle first")
    }
}

@Suite struct PostingCommandTests {
    @Test func postsMessagesWithReferencesAndFiles() throws {
        let home = try CLITestHome()
        let context = home.context()
        _ = try run(["session", "attach", "--repo", home.repo], context: context)

        let posted = try run(
            [
                "say", "Look at `src/lib.rs:4`",
                "--ref-heading", " Plan > Storage ",
                "--ref-snippet", "the snippet",
                "--file", "app/Jobs/Sync.php:14-20",
                "--file", "docs/x.md",
            ], context: context)
        #expect(posted == "posted say generated-1")
        let message = try #require(try home.store.messages(sessionId: "tuple-call-1").first)
        #expect(message.kind == .message)
        #expect(message.reference == DocumentReference(heading: ["Plan", "Storage"], snippet: "the snippet"))
        #expect(message.files.map(\.path) == ["app/Jobs/Sync.php", "docs/x.md", "src/lib.rs"])
        #expect(message.files[0].line == 14)
        #expect(message.files[0].endLine == 20)
        #expect(!message.read)

        let acked = try run(["ack", "noted"], context: context)
        #expect(acked == "posted ack generated-2")
        let ack = try #require(try home.store.messages(sessionId: "tuple-call-1").last)
        #expect(ack.kind == .ack)
        #expect(ack.read)

        let decided = try run(["decision", "Ship it", "--id", "adr-1"], context: context)
        #expect(decided == "posted decision adr-1")
        let decision = try #require(
            try home.store.messages(sessionId: "tuple-call-1").first { $0.id == "adr-1" })
        #expect(decision.kind == .decision)
        #expect(decision.decisionStatus == .unreviewed)
    }

    @Test func validatesReferencePairingAndKinds() throws {
        let home = try CLITestHome()
        let context = home.context()
        _ = try run(["session", "attach", "--repo", home.repo], context: context)

        #expect(
            runError(["say", "text", "--ref-heading", "A"], context: context)?.message
                == "--ref-heading and --ref-snippet must be supplied together")
        #expect(
            runError(["say", "text", "--ref-snippet", "s"], context: context)?.message
                == "--ref-heading and --ref-snippet must be supplied together")
        #expect(
            runError(
                ["say", "text", "--ref-heading", "A>>B", "--ref-snippet", "s"], context: context)?
                .message == "document reference heading and snippet cannot be empty")
        #expect(
            runError(
                ["say", "text", "--ref-heading", "A", "--ref-snippet", ""], context: context)?
                .message == "document reference heading and snippet cannot be empty")
        #expect(
            runError(
                ["ack", "text", "--ref-heading", "A", "--ref-snippet", "s"], context: context)?
                .message == "ack messages cannot carry a document reference")
        #expect(
            runError(["say", "text", "--id", "x"], context: context)?.message
                == "--id is only valid for decisions")
        #expect(
            runError(["ack", "text", "--id", "x"], context: context)?.message
                == "--id is only valid for decisions")
        #expect(runError(["say"], context: context)?.message == "say requires message text")
        #expect(
            runError(["say", "   "], context: context)?.message == "message text cannot be empty")
        #expect(
            runError(["say", "bad `../escape.txt` path", "--file", "../escape.txt"], context: context)?
                .message == "file references must be repository-relative paths: ../escape.txt")
    }

    @Test func validatesDecisionIds() throws {
        let home = try CLITestHome()
        let context = home.context()
        _ = try run(["session", "attach", "--repo", home.repo], context: context)
        #expect(
            runError(["decision", "text"], context: context)?.message
                == "decision requires --id <id>")
        #expect(
            runError(["decision", "text", "--id", "has space"], context: context)?.message
                == "decision ID must be non-empty and contain no whitespace")
        #expect(
            runError(["decision", "text", "--id", "  "], context: context)?.message
                == "decision ID must be non-empty and contain no whitespace")
        _ = try run(["decision", "text", "--id", "adr-1"], context: context)
        #expect(
            runError(["decision", "again", "--id", "adr-1"], context: context)?.message
                == "message ID already exists: adr-1")
    }

    @Test func unlinkAndReadRoundTrip() throws {
        let home = try CLITestHome()
        let context = home.context()
        _ = try run(["session", "attach", "--repo", home.repo], context: context)
        _ = try run(
            ["say", "with ref", "--ref-heading", "A", "--ref-snippet", "s"], context: context)
        _ = try run(["say", "plain"], context: context)

        #expect(runError(["unlink"], context: context)?.message == "unlink requires one message ID")
        #expect(
            runError(["unlink", "missing"], context: context)?.message
                == "message not found: missing")
        #expect(
            runError(["unlink", "generated-2"], context: context)?.message
                == "message has no document reference: generated-2")
        #expect(try run(["unlink", "generated-1"], context: context) == "unlinked generated-1")

        #expect(
            runError(["read", "missing"], context: context)?.message
                == "message not found or already read: missing")
        #expect(try run(["read", "generated-1"], context: context) == "marked generated-1 read")
        #expect(try run(["read"], context: context) == "marked all messages read")
        #expect(try home.store.messages(sessionId: "tuple-call-1").allSatisfy(\.read))
    }
}
