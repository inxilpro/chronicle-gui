import Foundation

/// Filesystem locations for the app's own data and for the IDE plugin's published data.
public struct ChroniclePaths: Sendable, Equatable {
    /// The app's data root. Defaults to `~/Library/Application Support/Chronicle`;
    /// `CHRONICLE_APP_HOME` overrides it for tests and isolated development.
    public var appHome: URL

    /// The stable CLI shim location; overridable so tests never touch the real home.
    public var shimURL: URL = ChroniclePaths.shimURL

    /// The installed skill file; overridable so tests never touch the real home.
    public var skillURL: URL = ChroniclePaths.skillDirectory.appendingPathComponent("SKILL.md")

    public init(appHome: URL) {
        self.appHome = appHome.standardizedFileURL
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["CHRONICLE_APP_HOME"], !override.isEmpty {
            self.init(appHome: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.init(appHome: base.appendingPathComponent("Chronicle", isDirectory: true))
        }
    }

    public var databaseURL: URL { appHome.appendingPathComponent("chronicle.db") }
    public var locksDirectory: URL { appHome.appendingPathComponent("locks", isDirectory: true) }
    public var sessionsDirectory: URL { appHome.appendingPathComponent("sessions", isDirectory: true) }

    public func sessionDirectory(sessionId: String) -> URL {
        sessionsDirectory.appendingPathComponent(Self.safeSessionId(sessionId), isDirectory: true)
    }

    public func notesURL(sessionId: String) -> URL {
        sessionDirectory(sessionId: sessionId).appendingPathComponent("notes.md")
    }

    /// The stable CLI shim the installed skill invokes.
    public static var shimURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chronicle/bin/chronicle")
    }

    public static var skillDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/chronicle", isDirectory: true)
    }

    /// The IDE plugin's publish root: explicit override, then `CHRONICLE_HOME`, then `~/.chronicle`.
    public static func ideRoot(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        if let env = environment["CHRONICLE_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chronicle", isDirectory: true)
    }

    public static func safeSessionId(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) {
            return id
        }
        return "call-" + String(SHA256Hex.hash(id).prefix(16))
    }
}
