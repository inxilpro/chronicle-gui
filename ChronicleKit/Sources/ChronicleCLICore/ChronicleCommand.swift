import ArgumentParser
import ChronicleKit
import Foundation

/// Everything a command needs, injectable so tests can drive the tree without
/// the real app home, Tuple binary, or wall clock.
public struct CLIContext {
    public var store: ChronicleStore
    public var provider: any CallProvider
    public var makeMessageId: () -> String
    public var now: () -> Date
    public var sleep: (TimeInterval) -> Void

    public init(
        store: ChronicleStore,
        provider: any CallProvider,
        makeMessageId: @escaping () -> String = { UUID().uuidString.lowercased() },
        now: @escaping () -> Date = { Date() },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.store = store
        self.provider = provider
        self.makeMessageId = makeMessageId
        self.now = now
        self.sleep = sleep
    }

    public static func live() throws -> CLIContext {
        CLIContext(
            store: try ChronicleStore(paths: ChroniclePaths()),
            provider: TupleClient.discover())
    }
}

protocol ChronicleExecutable {
    func execute(context: CLIContext) throws -> String
}

let chronicleUsage = """
    Usage:
      chronicle session attach --repo <path>
      chronicle session current --json
      chronicle session finish
      chronicle show [--wait] --cursor <name> [--timeout <duration>] [--limit <count>]
      chronicle working
      chronicle say <text> [--ref-heading <A>B>] [--ref-snippet <text>] [--file <path[:line[-end]]>]...
      chronicle ack <text> [--file <path[:line[-end]]>]...
      chronicle decision <text> --id <id> [--ref-heading <A>B>] [--ref-snippet <text>] [--file <path[:line[-end]]>]...
      chronicle unlink <message-id>
      chronicle read [<message-id>]

    Chronicle stores operational data in ~/Library/Application Support/Chronicle.
    The active Tuple call ID is the session ID. Run `session attach` from the
    repository being planned; it returns the internal handoff path. No command
    writes a sidecar or handoff into the repository.
    """

public struct ChronicleCommand: ParsableCommand, ChronicleExecutable {
    public static let configuration = CommandConfiguration(
        commandName: "chronicle",
        abstract: "Follow a Tuple planning call, keep the handoff, and speak through Chronicle.",
        discussion: """
        Chronicle stores operational data in ~/Library/Application Support/Chronicle. The active
        Tuple call ID is the session ID. Run `session attach` from the repository being planned;
        it returns the internal handoff path. No command writes a sidecar or handoff into the
        repository.
        """,
        subcommands: [
            SessionCommand.self, ShowCommand.self, WorkingCommand.self, SayCommand.self,
            AckCommand.self, DecisionCommand.self, UnlinkCommand.self, ReadCommand.self,
        ]
    )

    public init() {}

    func execute(context: CLIContext) throws -> String {
        throw ChronicleError(chronicleUsage)
    }
}

// MARK: - session

struct SessionCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Attach, inspect, or finish the current Chronicle session.",
        subcommands: [Attach.self, Current.self, Finish.self]
    )

    func execute(context: CLIContext) throws -> String {
        throw ChronicleError("session requires attach, current, or finish")
    }

    struct Attach: ParsableCommand, ChronicleExecutable {
        static let configuration = CommandConfiguration(
            commandName: "attach",
            abstract: "Attach the repository being planned to the current session.")

        @Option(name: .customLong("repo"), help: "Path inside the repository being planned.")
        var repo: String?

        func execute(context: CLIContext) throws -> String {
            guard let repo else {
                throw ChronicleError("usage: chronicle session attach --repo <path>")
            }
            let session = try Collector.ensureCurrentSession(store: context.store, provider: context.provider)
            let attached = try context.store.attachRepo(sessionId: session.id, repo: repo)
            try IDEIngestion.discover(store: context.store, session: attached)
            return try sessionJSON(store: context.store, session: attached)
        }
    }

    struct Current: ParsableCommand, ChronicleExecutable {
        static let configuration = CommandConfiguration(
            commandName: "current",
            abstract: "Print the current session as JSON.")

        @Flag(name: .customLong("json"), help: "Required; the output contract is JSON.")
        var json = false

        func execute(context: CLIContext) throws -> String {
            guard json else {
                throw ChronicleError("usage: chronicle session current --json")
            }
            guard let session = try context.store.currentSession() else {
                throw ChronicleError(
                    "no active or finalizing Chronicle session; join a Tuple call first")
            }
            return try sessionJSON(store: context.store, session: session)
        }
    }

    struct Finish: ParsableCommand, ChronicleExecutable {
        static let configuration = CommandConfiguration(
            commandName: "finish",
            abstract: "Complete a finalizing session after the handoff is done.")

        func execute(context: CLIContext) throws -> String {
            try? Collector.collectOnce(store: context.store, provider: context.provider, timeout: "1ms")
            guard let session = try context.store.currentSession() else {
                throw ChronicleError("no active or finalizing Chronicle session to finish")
            }
            try context.store.finishSession(session.id)
            struct FinishResult: Encodable {
                var sessionId: String
                var state: String
            }
            return try encodeJSON(FinishResult(sessionId: session.id, state: "complete"))
        }
    }
}

// MARK: - show

struct ShowCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Collect sources and deliver undelivered events for a cursor.")

    @Flag(help: "Wait until events are available or the timeout passes.")
    var wait = false

    @Option(help: "Durable consumer cursor name.")
    var cursor: String?

    @Option(help: "Wait budget, <digits>(ms|s|m), 1ms-5m.")
    var timeout = "30s"

    @Option(help: "Maximum events per response, 1-10000.")
    var limit = "200"

    func execute(context: CLIContext) throws -> String {
        guard let cursor else {
            throw ChronicleError("show requires --cursor <name>")
        }
        let timeoutMilliseconds = try validateTimeout(timeout)
        guard let limit = Int(self.limit) else {
            throw ChronicleError("--limit must be an integer")
        }
        let session = try Collector.ensureCurrentSession(store: context.store, provider: context.provider)
        if wait {
            // Collection is process-safe: GUI and CLI readers serialize on the
            // same per-call lock and share Tuple's durable chronicle-<call-id>
            // cursor. Waiting also watches local undelivered events, not only
            // Tuple's long poll.
            let deadline = context.now().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
            while true {
                // Events another process already collected deliver instantly.
                if try context.store.hasUndeliveredEvents(sessionId: session.id, consumer: cursor) {
                    break
                }
                let remaining = deadline.timeIntervalSince(context.now())
                if remaining <= 0 { break }
                let passMilliseconds = max(1, min(Int(remaining * 1000), 2000))
                let passStarted = context.now()
                try? Collector.collectOnce(
                    store: context.store, provider: context.provider, timeout: "\(passMilliseconds)ms")
                if try context.store.hasUndeliveredEvents(sessionId: session.id, consumer: cursor) {
                    break
                }
                if context.now() >= deadline { break }
                // A missing or failing Tuple CLI returns instantly; pace the
                // loop so it cannot spin.
                if context.now().timeIntervalSince(passStarted) < 0.1 {
                    context.sleep(0.1)
                }
            }
        } else {
            try? Collector.collectOnce(store: context.store, provider: context.provider, timeout: "1ms")
        }
        let result = try context.store.show(sessionId: session.id, consumer: cursor, limit: limit)
        return try encodeJSON(result)
    }
}

func validateTimeout(_ value: String) throws -> Int {
    guard let split = value.firstIndex(where: { !$0.isASCII || !$0.isNumber }) else {
        throw ChronicleError("--timeout must include ms, s, or m")
    }
    let digits = String(value[..<split])
    guard let number = UInt64(digits) else {
        throw ChronicleError("--timeout must start with an integer")
    }
    let milliseconds: UInt64
    switch String(value[split...]) {
    case "ms": milliseconds = number
    case "s": milliseconds = number.multipliedReportingOverflow(by: 1000).partialValue
    case "m": milliseconds = number.multipliedReportingOverflow(by: 60_000).partialValue
    default: throw ChronicleError("--timeout must use ms, s, or m")
    }
    if milliseconds == 0 || milliseconds > 300_000 {
        throw ChronicleError("--timeout must be between 1ms and 5m")
    }
    return Int(milliseconds)
}

// MARK: - working

struct WorkingCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "working",
        abstract: "Show the room that background work is happening.")

    func execute(context: CLIContext) throws -> String {
        let session = try Collector.ensureCurrentSession(store: context.store, provider: context.provider)
        try context.store.signalAgentWorking(sessionId: session.id, now: context.now())
        return "working"
    }
}

// MARK: - say / ack / decision

struct SayCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "say",
        abstract: "Post a message to the room.")

    @Argument(help: "Message text.")
    var text: String?

    @Option(name: .customLong("id"), help: .hidden)
    var id: String?

    @OptionGroup var reference: ReferenceOptions
    @OptionGroup var files: FileOptions

    func execute(context: CLIContext) throws -> String {
        try postMessage(
            command: "say", text: text, id: id, reference: reference, files: files,
            context: context)
    }
}

struct AckCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "ack",
        abstract: "Post a quiet acknowledgment.")

    @Argument(help: "Acknowledgment text.")
    var text: String?

    @Option(name: .customLong("id"), help: .hidden)
    var id: String?

    @OptionGroup var reference: ReferenceOptions
    @OptionGroup var files: FileOptions

    func execute(context: CLIContext) throws -> String {
        try postMessage(
            command: "ack", text: text, id: id, reference: reference, files: files,
            context: context)
    }
}

struct DecisionCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "decision",
        abstract: "Post a decision card for the room to approve or reject.")

    @Argument(help: "Decision text.")
    var text: String?

    @Option(name: .customLong("id"), help: "Stable decision ID; also the message ID.")
    var id: String?

    @OptionGroup var reference: ReferenceOptions
    @OptionGroup var files: FileOptions

    func execute(context: CLIContext) throws -> String {
        try postMessage(
            command: "decision", text: text, id: id, reference: reference, files: files,
            context: context)
    }
}

struct ReferenceOptions: ParsableArguments {
    @Option(name: .customLong("ref-heading"), help: "Heading path, components separated by '>'.")
    var refHeading: String?

    @Option(name: .customLong("ref-snippet"), help: "Exact snippet under the referenced heading.")
    var refSnippet: String?

    func build() throws -> DocumentReference? {
        switch (refHeading, refSnippet) {
        case (.some(let heading), .some(let snippet)):
            let components = heading.split(separator: ">", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if components.isEmpty || components.contains(where: \.isEmpty) || snippet.isEmpty {
                throw ChronicleError("document reference heading and snippet cannot be empty")
            }
            return DocumentReference(heading: components, snippet: snippet)
        case (.none, .none):
            return nil
        default:
            throw ChronicleError("--ref-heading and --ref-snippet must be supplied together")
        }
    }
}

struct FileOptions: ParsableArguments {
    @Option(
        name: .customLong("file"), parsing: .singleValue,
        help: "File reference, path[:line[-end]]; repeatable.")
    var files: [String] = []
}

private func postMessage(
    command: String, text: String?, id: String?,
    reference: ReferenceOptions, files: FileOptions, context: CLIContext
) throws -> String {
    guard let text else {
        throw ChronicleError("\(command) requires message text")
    }
    if text.hasPrefix("--") {
        throw ChronicleError("\(command) requires message text before options")
    }
    let documentReference = try reference.build()
    let kind: MessageKind
    let messageId: String
    switch command {
    case "say":
        if id != nil {
            throw ChronicleError("--id is only valid for decisions")
        }
        kind = .message
        messageId = context.makeMessageId()
    case "ack":
        if documentReference != nil {
            throw ChronicleError("ack messages cannot carry a document reference")
        }
        if id != nil {
            throw ChronicleError("--id is only valid for decisions")
        }
        kind = .ack
        messageId = context.makeMessageId()
    default:
        guard let id else {
            throw ChronicleError("decision requires --id <id>")
        }
        if id.trimmingCharacters(in: .whitespaces).isEmpty || id.contains(where: \.isWhitespace) {
            throw ChronicleError("decision ID must be non-empty and contain no whitespace")
        }
        kind = .decision
        messageId = id
    }
    let session = try Collector.ensureCurrentSession(store: context.store, provider: context.provider)
    try context.store.postMessage(
        session: session, id: messageId, kind: kind, text: text,
        reference: documentReference, explicitFiles: files.files)
    return "posted \(command) \(messageId)"
}

// MARK: - unlink / read

struct UnlinkCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "unlink",
        abstract: "Remove a message's document reference.")

    @Argument(help: "Message ID.")
    var messageId: String?

    func execute(context: CLIContext) throws -> String {
        guard let messageId else {
            throw ChronicleError("unlink requires one message ID")
        }
        let session = try Collector.ensureCurrentSession(store: context.store, provider: context.provider)
        try context.store.unlink(sessionId: session.id, messageId: messageId)
        return "unlinked \(messageId)"
    }
}

struct ReadCommand: ParsableCommand, ChronicleExecutable {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Mark one message read, or all messages.")

    @Argument(help: "Message ID; omit to mark all messages read.")
    var messageId: String?

    func execute(context: CLIContext) throws -> String {
        let session = try Collector.ensureCurrentSession(store: context.store, provider: context.provider)
        try context.store.markRead(sessionId: session.id, messageId: messageId)
        if let messageId {
            return "marked \(messageId) read"
        }
        return "marked all messages read"
    }
}

// MARK: - Output encoding

private let outputEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return encoder
}()

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    do {
        return String(decoding: try outputEncoder.encode(value), as: UTF8.self)
    } catch {
        throw ChronicleError("cannot encode command response: \(error.localizedDescription)")
    }
}

func sessionJSON(store: ChronicleStore, session: SessionRecord) throws -> String {
    try encodeJSON(
        SessionInfo(
            sessionId: session.id, state: session.state,
            notesPath: session.notesPath, repoPath: session.repoPath,
            sourceHealth: try store.sourceHealth(sessionId: session.id)))
}

// MARK: - Entry points

/// Drives the parsed command tree; tests inject their own context.
public enum ChronicleCLIRunner {
    public static func run(_ arguments: [String], context: CLIContext) throws -> String {
        let command = try ChronicleCommand.parseAsRoot(arguments)
        guard let executable = command as? ChronicleExecutable else {
            var help = command
            try help.run()
            return ""
        }
        return try executable.execute(context: context)
    }
}

/// Entry point for the `chronicle` executable target, which does not import ArgumentParser itself.
public enum ChronicleCLI {
    public static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let command = try ChronicleCommand.parseAsRoot(arguments)
            guard let executable = command as? ChronicleExecutable else {
                var help = command
                try help.run()
                return
            }
            let output = try executable.execute(context: try CLIContext.live())
            if !output.isEmpty {
                print(output)
            }
        } catch let error as ChronicleError {
            FileHandle.standardError.write(Data("chronicle: \(error.message)\n".utf8))
            Foundation.exit(1)
        } catch {
            ChronicleCommand.exit(withError: error)
        }
    }
}
