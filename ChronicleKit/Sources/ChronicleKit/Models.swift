import Foundation

public enum SessionState: String, Codable, Sendable, Equatable {
    case active, finalizing, complete, interrupted
}

public enum AppMode: String, Codable, Sendable, Equatable {
    case waitingCall, waitingTranscription, waitingClaude
    case active, finalizing, complete, interrupted
}

public enum MessageKind: String, Codable, Sendable, Equatable {
    case message, ack, decision
}

public enum DecisionStatus: String, Codable, Sendable, Equatable {
    case unreviewed, approved, rejected
}

public struct DocumentReference: Codable, Sendable, Equatable, Hashable {
    public var heading: [String]
    public var snippet: String

    public init(heading: [String], snippet: String) {
        self.heading = heading
        self.snippet = snippet
    }
}

public struct FileReference: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public var line: Int?
    public var endLine: Int?
    public var sha: String

    public init(path: String, line: Int? = nil, endLine: Int? = nil, sha: String) {
        self.path = path
        self.line = line
        self.endLine = endLine
        self.sha = sha
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: MessageKind
    public var timestamp: String
    public var text: String
    public var reference: DocumentReference?
    public var files: [FileReference]
    public var read: Bool
    public var decisionStatus: DecisionStatus?

    public init(
        id: String, kind: MessageKind, timestamp: String, text: String,
        reference: DocumentReference? = nil, files: [FileReference] = [],
        read: Bool = false, decisionStatus: DecisionStatus? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
        self.reference = reference
        self.files = files
        self.read = read
        self.decisionStatus = decisionStatus
    }
}

public enum SourceName {
    public static let tuple = "tuple"
    public static let claude = "claude"
    /// The IDE plugin, as shown to the skill and the UI.
    public static let chronicle = "chronicle"
}

public enum SourceStatus: String, Codable, Sendable, Equatable {
    case live, connected, waiting, stopped, ended, ambiguous, error, off

    public var label: String {
        switch self {
        case .live: "Live"
        case .connected: "Connected"
        case .waiting: "Waiting"
        case .stopped: "Stopped"
        case .ended: "Ended"
        case .ambiguous: "Choose source"
        case .error: "Needs attention"
        case .off: "Off"
        }
    }
}

public struct SourceHealth: Codable, Sendable, Equatable {
    public var source: String
    public var status: String
    public var label: String
    public var detail: String?

    public init(source: String, status: SourceStatus, detail: String? = nil) {
        self.source = source
        self.status = status.rawValue
        self.label = status.label
        self.detail = detail
    }

    public init(source: String, status: String, label: String, detail: String? = nil) {
        self.source = source
        self.status = status
        self.label = label
        self.detail = detail
    }
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var state: SessionState
    public var startedAt: String
    public var updatedAt: String
    public var attachedRepo: String?
    public var hasUnsavedHandoff: Bool
    public var dataPruned: Bool

    public init(
        id: String, state: SessionState, startedAt: String, updatedAt: String,
        attachedRepo: String? = nil, hasUnsavedHandoff: Bool = false, dataPruned: Bool = false
    ) {
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.attachedRepo = attachedRepo
        self.hasUnsavedHandoff = hasUnsavedHandoff
        self.dataPruned = dataPruned
    }
}

public struct IDERepository: Codable, Sendable, Equatable, Hashable {
    public var root: String
    public var branch: String?

    public init(root: String, branch: String? = nil) {
        self.root = root
        self.branch = branch
    }
}

public enum IDESessionState: String, Codable, Sendable, Equatable {
    case active, completed, interrupted
}

/// An entry from the IDE plugin's `sessions.json` registry.
public struct IDESessionCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var state: IDESessionState
    public var logPath: String
    public var projectName: String
    public var projectRoot: String
    public var repositories: [IDERepository]
    public var startedAt: String
    public var lastEventAt: String
    public var endedAt: String?

    public init(
        id: String, state: IDESessionState, logPath: String, projectName: String,
        projectRoot: String, repositories: [IDERepository],
        startedAt: String, lastEventAt: String, endedAt: String? = nil
    ) {
        self.id = id
        self.state = state
        self.logPath = logPath
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.repositories = repositories
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.endedAt = endedAt
    }
}

public struct NormalizedEvent: Codable, Sendable, Equatable {
    public var stableId: String
    /// "tuple" | "ide" (imported from the IDE plugin) | "chronicle" (synthetic review events).
    public var source: String
    public var streamId: String?
    public var sourceSequence: Int64?
    public var occurredAt: String
    public var observedAt: String
    public var kind: String
    public var payload: JSONValue

    public init(
        stableId: String, source: String, streamId: String? = nil, sourceSequence: Int64? = nil,
        occurredAt: String, observedAt: String, kind: String, payload: JSONValue
    ) {
        self.stableId = stableId
        self.source = source
        self.streamId = streamId
        self.sourceSequence = sourceSequence
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.kind = kind
        self.payload = payload
    }
}

/// Output of `chronicle show`.
public struct ShowResult: Codable, Sendable, Equatable {
    public var sessionId: String
    public var sessionState: SessionState
    public var notesPath: String
    public var repoPath: String?
    public var sourceHealth: [SourceHealth]
    public var events: [NormalizedEvent]
    public var hasMore: Bool

    public init(
        sessionId: String, sessionState: SessionState, notesPath: String, repoPath: String?,
        sourceHealth: [SourceHealth], events: [NormalizedEvent], hasMore: Bool
    ) {
        self.sessionId = sessionId
        self.sessionState = sessionState
        self.notesPath = notesPath
        self.repoPath = repoPath
        self.sourceHealth = sourceHealth
        self.events = events
        self.hasMore = hasMore
    }
}

/// Output of `chronicle session attach` and `chronicle session current`.
public struct SessionInfo: Codable, Sendable, Equatable {
    public var sessionId: String
    public var state: SessionState
    public var notesPath: String
    public var repoPath: String?
    public var sourceHealth: [SourceHealth]

    public init(
        sessionId: String, state: SessionState, notesPath: String,
        repoPath: String?, sourceHealth: [SourceHealth]
    ) {
        self.sessionId = sessionId
        self.state = state
        self.notesPath = notesPath
        self.repoPath = repoPath
        self.sourceHealth = sourceHealth
    }
}

public struct AppSnapshot: Codable, Sendable, Equatable {
    public var mode: AppMode
    public var sessionId: String?
    public var sessionState: SessionState?
    public var notesPath: String?
    public var repoPath: String?
    public var markdown: String
    public var messages: [ChatMessage]
    public var sources: [SourceHealth]
    public var sessions: [SessionSummary]
    public var ideCandidates: [IDESessionCandidate]
    public var ideRoot: String
    public var ideRegistryFound: Bool
    public var integrationInstalled: Bool
    public var handoffSaved: Bool

    public init(
        mode: AppMode, sessionId: String? = nil, sessionState: SessionState? = nil,
        notesPath: String? = nil, repoPath: String? = nil, markdown: String = "",
        messages: [ChatMessage] = [], sources: [SourceHealth] = [],
        sessions: [SessionSummary] = [], ideCandidates: [IDESessionCandidate] = [],
        ideRoot: String = "", ideRegistryFound: Bool = false,
        integrationInstalled: Bool = false, handoffSaved: Bool = false
    ) {
        self.mode = mode
        self.sessionId = sessionId
        self.sessionState = sessionState
        self.notesPath = notesPath
        self.repoPath = repoPath
        self.markdown = markdown
        self.messages = messages
        self.sources = sources
        self.sessions = sessions
        self.ideCandidates = ideCandidates
        self.ideRoot = ideRoot
        self.ideRegistryFound = ideRegistryFound
        self.integrationInstalled = integrationInstalled
        self.handoffSaved = handoffSaved
    }
}
