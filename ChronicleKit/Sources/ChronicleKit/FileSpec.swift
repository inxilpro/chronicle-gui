import Foundation

/// A repository-relative file location parsed from `path[:line[-endLine]]`.
public struct FileSpec: Sendable, Equatable, Hashable {
    public var path: String
    public var line: Int?
    public var endLine: Int?

    public init(path: String, line: Int? = nil, endLine: Int? = nil) {
        self.path = path
        self.line = line
        self.endLine = endLine
    }

    public static func parse(_ spec: String) throws -> FileSpec {
        let spec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.isEmpty || spec.contains("://") {
            throw ChronicleError("invalid file reference: \(spec)")
        }
        var path = spec
        var line: Int?
        var endLine: Int?
        if let colon = spec.lastIndex(of: ":") {
            let suffix = String(spec[spec.index(after: colon)...])
            if let first = suffix.utf8.first, (0x30...0x39).contains(first) {
                if let dash = suffix.firstIndex(of: "-") {
                    line = try parseLine(String(suffix[..<dash]), spec: spec)
                    endLine = try parseLine(String(suffix[suffix.index(after: dash)...]), spec: spec)
                } else {
                    line = try parseLine(suffix, spec: spec)
                }
                if let line, let endLine, endLine < line {
                    throw ChronicleError("file reference has a backwards line range: \(spec)")
                }
                path = String(spec[..<colon])
            }
        }
        if path.hasPrefix("./") {
            path = String(path.dropFirst(2))
        }
        path = path.replacingOccurrences(of: "\\", with: "/")
        let components = path.split(separator: "/")
        if path.isEmpty
            || path.hasPrefix("/")
            || path.contains(":")
            || components.contains("..")
        {
            throw ChronicleError("file references must be repository-relative paths: \(spec)")
        }
        return FileSpec(path: path, line: line, endLine: endLine)
    }

    private static func parseLine(_ value: String, spec: String) throws -> Int {
        guard let line = Int(value), value.allSatisfy(\.isNumber) else {
            throw ChronicleError("invalid line number in file reference: \(spec)")
        }
        if line == 0 {
            throw ChronicleError("line numbers start at 1: \(spec)")
        }
        return line
    }

    /// Backticked tokens in message text that contain a path separator and no
    /// whitespace are treated as file references.
    public static func inferred(from text: String) -> [FileSpec] {
        var result: [FileSpec] = []
        var remaining = Substring(text)
        while let open = remaining.firstIndex(of: "`") {
            remaining = remaining[remaining.index(after: open)...]
            guard let close = remaining.firstIndex(of: "`") else { break }
            let candidate = String(remaining[..<close])
            if (candidate.contains("/") || candidate.contains("\\")),
                !candidate.contains(where: \.isWhitespace),
                let spec = try? parse(candidate),
                !result.contains(spec)
            {
                result.append(spec)
            }
            remaining = remaining[remaining.index(after: close)...]
        }
        return result
    }
}
