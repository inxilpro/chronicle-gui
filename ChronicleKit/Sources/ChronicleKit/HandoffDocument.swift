import Foundation
import Markdown

/// A parsed view of the session handoff: blocks with heading context, decision
/// markers, resolvable document references, and inline file references. Pure
/// model — the SwiftUI renderer builds on it.
public struct HandoffDocument: Sendable, Equatable {
    /// The original markdown as written by Claude.
    public let markdown: String

    /// The markdown with HTML comments outside code fences removed. Document
    /// references resolve against this text, which is what the renderer shows.
    public let strippedMarkdown: String

    public let blocks: [Block]
    public let decisionMarkers: [DecisionMarker]
    public let fileReferences: [InlineFileReference]

    public struct Block: Sendable, Equatable {
        /// Heading titles from the document root down to (and including, for
        /// heading blocks) this block's section.
        public var headingPath: [String]
        /// Stable slug anchor for the enclosing section.
        public var anchor: String
        public var isHeading: Bool
        /// Heading level for heading blocks.
        public var level: Int?
        /// The block's source text within `strippedMarkdown`.
        public var text: String
        /// UTF-16 offset range within `strippedMarkdown`.
        public var range: Range<Int>
    }

    public struct DecisionMarker: Sendable, Equatable {
        public var id: String
        public var headingPath: [String]
        public var anchor: String
    }

    public struct InlineFileReference: Sendable, Equatable {
        public var path: String
        public var line: Int?
        public var endLine: Int?
        public var sha: String?
        public var headingPath: [String]
    }

    public struct ResolvedLocation: Sendable, Equatable {
        public var headingPath: [String]
        public var anchor: String
        /// UTF-16 offset range of the snippet within `strippedMarkdown`.
        public var snippetRange: Range<Int>
    }

    public init(markdown: String) {
        self.markdown = markdown
        let (stripped, comments) = Self.stripComments(markdown)
        strippedMarkdown = stripped

        let document = Document(parsing: stripped)
        let lineOffsets = Self.lineOffsets(stripped)

        var blocks: [Block] = []
        var headingStack: [(level: Int, title: String)] = []
        var anchorCounts: [String: Int] = [:]
        var lineHeadingPaths: [(line: Int, path: [String], anchor: String)] = []
        var currentAnchor = ""

        for child in document.children {
            guard let range = child.range else { continue }
            let startLine = range.lowerBound.line
            let endLine = range.upperBound.line
            let offsetRange = Self.offsetRange(
                lines: lineOffsets, startLine: startLine, endLine: endLine, in: stripped)
            let text = Self.substring(stripped, utf16Range: offsetRange)
            if let heading = child as? Heading {
                while let last = headingStack.last, last.level >= heading.level {
                    headingStack.removeLast()
                }
                headingStack.append((heading.level, heading.plainText))
                let path = headingStack.map(\.title)
                var anchor = Self.slug(path)
                let count = anchorCounts[anchor, default: 0] + 1
                anchorCounts[anchor] = count
                if count > 1 {
                    anchor += "-\(count)"
                }
                currentAnchor = anchor
                blocks.append(
                    Block(
                        headingPath: path, anchor: anchor, isHeading: true,
                        level: heading.level, text: text, range: offsetRange))
                lineHeadingPaths.append((startLine, path, anchor))
            } else {
                blocks.append(
                    Block(
                        headingPath: headingStack.map(\.title), anchor: currentAnchor,
                        isHeading: false, level: nil, text: text, range: offsetRange))
            }
        }
        self.blocks = blocks

        func context(atLine line: Int) -> (path: [String], anchor: String) {
            var result: (path: [String], anchor: String) = ([], "")
            for entry in lineHeadingPaths where entry.line <= line {
                result = (entry.path, entry.anchor)
            }
            return result
        }

        decisionMarkers = comments.compactMap { comment in
            guard let id = Self.decisionId(in: comment.text) else { return nil }
            let (path, anchor) = context(atLine: comment.line)
            return DecisionMarker(id: id, headingPath: path, anchor: anchor)
        }

        var references: [InlineFileReference] = []
        var collector = InlineCodeCollector()
        collector.visit(document)
        for found in collector.found {
            guard let parsed = Self.parseFileReference(code: found.code, following: found.following)
            else { continue }
            let (path, _) = context(atLine: found.line)
            references.append(
                InlineFileReference(
                    path: parsed.path, line: parsed.line, endLine: parsed.endLine,
                    sha: parsed.sha, headingPath: path))
        }
        fileReferences = references
    }

    /// Renderer helper: interprets one inline-code span (plus the text that
    /// immediately follows it) with the same grammar used for `fileReferences`.
    /// Returns nil when the span is not a file reference.
    public static func inlineFileReference(code: String, following: String?) -> InlineFileReference? {
        guard let parsed = parseFileReference(code: code, following: following) else { return nil }
        return InlineFileReference(
            path: parsed.path, line: parsed.line, endLine: parsed.endLine,
            sha: parsed.sha, headingPath: [])
    }

    /// Heading path match, then the first exact substring match of the snippet
    /// before the next same-or-higher heading. The reference may omit ancestor
    /// headings (typically the document title): a heading matches when its full
    /// path ends with the referenced components.
    public func resolve(_ reference: DocumentReference) -> ResolvedLocation? {
        let target = reference.heading.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !target.isEmpty else { return nil }
        for (index, block) in blocks.enumerated() where block.isHeading {
            let path = block.headingPath.map { $0.trimmingCharacters(in: .whitespaces) }
            guard path.count >= target.count, path.suffix(target.count).elementsEqual(target),
                let level = block.level
            else { continue }
            var sectionEnd = strippedMarkdown.utf16.count
            for next in blocks[(index + 1)...] where next.isHeading {
                if let nextLevel = next.level, nextLevel <= level {
                    sectionEnd = next.range.lowerBound
                    break
                }
            }
            let sectionRange = block.range.upperBound..<sectionEnd
            let section = Self.substring(strippedMarkdown, utf16Range: sectionRange)
            if let found = section.range(of: reference.snippet) {
                let offset = section.utf16.distance(from: section.startIndex, to: found.lowerBound)
                let length = reference.snippet.utf16.count
                let start = sectionRange.lowerBound + offset
                return ResolvedLocation(
                    headingPath: block.headingPath, anchor: block.anchor,
                    snippetRange: start..<(start + length))
            }
        }
        return nil
    }

    // MARK: - Slugs

    public static func slug(_ components: [String]) -> String {
        components.map(slugComponent).joined(separator: "--")
    }

    private static func slugComponent(_ text: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !result.isEmpty {
                    result.append("-")
                }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return result
    }

    // MARK: - Comment stripping

    struct Comment {
        var text: String
        var line: Int
    }

    /// Removes `<!-- … -->` outside fenced code blocks, returning the cleaned
    /// text and each removed comment with the line it started on.
    static func stripComments(_ markdown: String) -> (stripped: String, comments: [Comment]) {
        var output = ""
        output.reserveCapacity(markdown.count)
        var comments: [Comment] = []
        var inFence = false
        var fenceMarker: Character = "`"
        var inComment = false
        var commentText = ""
        var commentLine = 0

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let isLast = index == lines.count - 1
            let line = String(rawLine)
            if inComment {
                if let end = line.range(of: "-->") {
                    commentText += "\n" + line[..<end.lowerBound]
                    comments.append(Comment(text: commentText, line: commentLine))
                    inComment = false
                    let rest = String(line[end.upperBound...])
                    let (cleaned, _) = stripLine(
                        rest, lineNumber: lineNumber, inComment: &inComment,
                        commentText: &commentText, commentLine: &commentLine, comments: &comments)
                    appendLine(&output, cleaned, isLast: isLast)
                } else {
                    commentText += "\n" + line
                }
                continue
            }
            let trimmed = line.drop(while: { $0 == " " })
            if !inFence, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = trimmed.first ?? "`"
                appendLine(&output, line, isLast: isLast)
                continue
            }
            if inFence {
                if trimmed.hasPrefix(String(repeating: String(fenceMarker), count: 3)) {
                    inFence = false
                }
                appendLine(&output, line, isLast: isLast)
                continue
            }
            let (cleaned, _) = stripLine(
                line, lineNumber: lineNumber, inComment: &inComment,
                commentText: &commentText, commentLine: &commentLine, comments: &comments)
            appendLine(&output, cleaned, isLast: isLast)
        }
        if inComment {
            comments.append(Comment(text: commentText, line: commentLine))
        }
        return (output, comments)
    }

    private static func appendLine(_ output: inout String, _ line: String, isLast: Bool) {
        output += line
        if !isLast {
            output += "\n"
        }
    }

    private static func stripLine(
        _ line: String, lineNumber: Int, inComment: inout Bool,
        commentText: inout String, commentLine: inout Int, comments: inout [Comment]
    ) -> (String, Bool) {
        var cleaned = ""
        var remaining = Substring(line)
        while let start = remaining.range(of: "<!--") {
            cleaned += remaining[..<start.lowerBound]
            let afterStart = remaining[start.upperBound...]
            if let end = afterStart.range(of: "-->") {
                comments.append(
                    Comment(text: String(afterStart[..<end.lowerBound]), line: lineNumber))
                remaining = afterStart[end.upperBound...]
            } else {
                inComment = true
                commentText = String(afterStart)
                commentLine = lineNumber
                return (cleaned, true)
            }
        }
        cleaned += remaining
        return (cleaned, false)
    }

    static func decisionId(in comment: String) -> String? {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("chronicle-decision:") else { return nil }
        let id = trimmed.dropFirst("chronicle-decision:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
        return id
    }

    // MARK: - File references

    struct ParsedFileReference: Equatable {
        var path: String
        var line: Int? = nil
        var endLine: Int? = nil
        var sha: String? = nil
    }

    /// `path[:line[-end]]` in inline code, optionally followed by ` @<4-64 hex>`
    /// in the adjacent text. Rejects absolute paths, `..`, whitespace, URLs,
    /// and extension-less bare names without a SHA.
    static func parseFileReference(code: String, following: String?) -> ParsedFileReference? {
        if code.isEmpty || code.contains(where: \.isWhitespace) || code.contains("://") {
            return nil
        }
        var path = code
        var line: Int?
        var endLine: Int?
        if let colon = code.lastIndex(of: ":") {
            let suffix = String(code[code.index(after: colon)...])
            guard let first = suffix.first, first.isNumber else { return nil }
            if let dash = suffix.firstIndex(of: "-") {
                guard let start = strictLine(String(suffix[..<dash])),
                    let end = strictLine(String(suffix[suffix.index(after: dash)...])),
                    end >= start
                else { return nil }
                line = start
                endLine = end
            } else {
                guard let start = strictLine(suffix) else { return nil }
                line = start
            }
            path = String(code[..<colon])
        }
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") || path.contains(":") {
            return nil
        }
        let components = path.split(separator: "/")
        if components.contains("..") || components.isEmpty {
            return nil
        }
        let sha = following.flatMap(parseSHA)
        if sha == nil {
            let hasDirectory = path.contains("/")
            let hasExtension = components.last?.contains(".") ?? false
            if !hasDirectory && !hasExtension {
                return nil
            }
        }
        return ParsedFileReference(path: path, line: line, endLine: endLine, sha: sha)
    }

    private static func strictLine(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text), value >= 1 else {
            return nil
        }
        return value
    }

    private static func parseSHA(_ following: String) -> String? {
        guard following.hasPrefix(" @") else { return nil }
        let rest = following.dropFirst(2)
        var sha = ""
        for character in rest {
            if character.isHexDigit && (character.isNumber || character.isLowercase) {
                sha.append(character)
            } else {
                break
            }
        }
        guard sha.count >= 4, sha.count <= 64 else { return nil }
        // A longer hex-ish run than 64 is not a SHA reference.
        let next = rest.dropFirst(sha.count).first
        if let next, next.isHexDigit && (next.isNumber || next.isLowercase) {
            return nil
        }
        return sha
    }

    // MARK: - Offsets

    private static func lineOffsets(_ text: String) -> [Int] {
        var offsets = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == UInt16(UnicodeScalar("\n").value) {
                offsets.append(offset)
            }
        }
        return offsets
    }

    private static func offsetRange(
        lines: [Int], startLine: Int, endLine: Int, in text: String
    ) -> Range<Int> {
        let start = lines.indices.contains(startLine - 1) ? lines[startLine - 1] : 0
        let end: Int
        if lines.indices.contains(endLine) {
            // Up to (not including) the newline that ends the last line.
            end = max(start, lines[endLine] - 1)
        } else {
            end = text.utf16.count
        }
        return start..<end
    }

    private static func substring(_ text: String, utf16Range range: Range<Int>) -> String {
        let utf16 = text.utf16
        guard
            let start = utf16.index(
                utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex),
            let end = utf16.index(
                utf16.startIndex, offsetBy: range.upperBound, limitedBy: utf16.endIndex),
            let stringStart = String.Index(start, within: text),
            let stringEnd = String.Index(end, within: text)
        else { return "" }
        return String(text[stringStart..<stringEnd])
    }
}

private struct InlineCodeCollector: MarkupWalker {
    struct Found {
        var code: String
        var line: Int
        var following: String?
    }

    var found: [Found] = []

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        var following: String?
        if let parent = inlineCode.parent,
            inlineCode.indexInParent + 1 < parent.childCount,
            let text = parent.child(at: inlineCode.indexInParent + 1) as? Text
        {
            following = text.string
        }
        found.append(
            Found(
                code: inlineCode.code,
                line: inlineCode.range?.lowerBound.line ?? 1,
                following: following))
    }
}
