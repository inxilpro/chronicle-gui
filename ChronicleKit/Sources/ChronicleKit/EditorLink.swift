import Foundation

/// The configured "open in editor" target and its URL grammar (SPEC §7 / UI §7).
public enum EditorApp: String, CaseIterable, Identifiable, Sendable {
    case phpstorm, idea, vscode, cursor, custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .phpstorm: "PhpStorm"
        case .idea: "IntelliJ IDEA"
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .custom: "Custom…"
        }
    }
}

public enum EditorLink {
    /// Builds the URL that opens `absolutePath` at `line` in the chosen editor.
    /// For `.custom`, `template` is a URL string with `{path}` and `{line}`
    /// placeholders. Returns nil when the result is not a valid URL.
    public static func url(
        editor: EditorApp, absolutePath: String, line: Int?, template: String = ""
    ) -> URL? {
        let line = line.map { max($0, 1) }
        switch editor {
        case .phpstorm, .idea:
            var components = URLComponents()
            components.scheme = editor == .phpstorm ? "phpstorm" : "idea"
            components.host = "open"
            var items = [URLQueryItem(name: "file", value: absolutePath)]
            if let line {
                items.append(URLQueryItem(name: "line", value: String(line)))
            }
            components.queryItems = items
            return components.url
        case .vscode, .cursor:
            let scheme = editor == .vscode ? "vscode" : "cursor"
            guard let escaped = escapePath(absolutePath) else { return nil }
            let suffix = line.map { ":\($0)" } ?? ""
            return URL(string: "\(scheme)://file\(escaped)\(suffix)")
        case .custom:
            guard let escaped = absolutePath.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "&?=")))
            else { return nil }
            let filled = template
                .replacingOccurrences(of: "{path}", with: escaped)
                .replacingOccurrences(of: "{line}", with: String(line ?? 1))
            guard !filled.isEmpty else { return nil }
            return URL(string: filled)
        }
    }

    /// Resolves a repo-relative file reference against the attached repository root.
    public static func absolutePath(repoRoot: String?, referencePath: String) -> String? {
        if referencePath.hasPrefix("/") { return referencePath }
        guard let repoRoot, !repoRoot.isEmpty else { return nil }
        return (repoRoot as NSString).appendingPathComponent(referencePath)
    }

    private static func escapePath(_ path: String) -> String? {
        let escaped = path.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":")))
        }
        guard !escaped.contains(nil) else { return nil }
        return escaped.compactMap { $0 }.joined(separator: "/")
    }
}

/// A clickable inline file reference inside the rendered handoff.
public struct FileLink: Equatable, Codable, Sendable {
    public var path: String
    public var line: Int?
    public var endLine: Int?
    public var sha: String?

    public static let scheme = "chronicle-file"

    public init(path: String, line: Int? = nil, endLine: Int? = nil, sha: String? = nil) {
        self.path = path
        self.line = line
        self.endLine = endLine
        self.sha = sha
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let path = items.first(where: { $0.name == "path" })?.value
        else { return nil }
        self.path = path
        line = items.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
        endLine = items.first(where: { $0.name == "endLine" })?.value.flatMap(Int.init)
        sha = items.first(where: { $0.name == "sha" })?.value
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: path)]
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let endLine { items.append(URLQueryItem(name: "endLine", value: String(endLine))) }
        if let sha { items.append(URLQueryItem(name: "sha", value: sha)) }
        components.queryItems = items
        return components.url
    }

    public var pathWithLine: String {
        guard let line else { return path }
        guard let endLine, endLine != line else { return "\(path):\(line)" }
        return "\(path):\(line)-\(endLine)"
    }

    public var helpText: String {
        guard let sha else { return "Open file" }
        return "Open file · commit \(sha.prefix(7))"
    }
}

/// Pure formatting helpers for the review feed.
public enum FeedFormat {
    /// Unread pill text, capped per the design contract.
    public static func unreadLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// Decision card titles reflect review state so a reviewed card never
    /// keeps reading "Decision requested".
    public static func decisionTitle(_ status: DecisionStatus) -> String {
        switch status {
        case .unreviewed: "Decision requested"
        case .approved: "Decision approved"
        case .rejected: "Decision rejected"
        }
    }

    public static func coalescedMessageBody(_ count: Int) -> String {
        count == 1
            ? "The agent added a new review note."
            : "The agent added \(count) new review notes."
    }

    /// "heading › path — snippet" for the Copy Reference affordance.
    public static func referencePasteboardText(_ reference: DocumentReference) -> String {
        let heading = reference.heading.joined(separator: " › ")
        if heading.isEmpty { return reference.snippet }
        return "\(heading) — \(reference.snippet)"
    }

    public static func pathWithLine(_ file: FileReference) -> String {
        guard let line = file.line else { return file.path }
        guard let end = file.endLine, end != line else { return "\(file.path):\(line)" }
        return "\(file.path):\(line)-\(end)"
    }
}
