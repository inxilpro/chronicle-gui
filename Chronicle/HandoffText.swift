import AppKit
import ChronicleKit

/// The fully laid-out handoff: attributed text plus source↔rendered maps used
/// for anchor scrolling, snippet highlighting, and Copy as Markdown.
struct HandoffRendering {
    struct RenderedBlock {
        var anchor: String
        var isHeading: Bool
        /// UTF-16 range in `HandoffDocument.strippedMarkdown`.
        var sourceRange: Range<Int>
        var sourceText: String
        var renderedRange: NSRange
    }

    let id: UUID
    let text: NSAttributedString
    let blocks: [RenderedBlock]
    /// First rendered range per heading anchor, in document order.
    let headingAnchors: [(anchor: String, range: NSRange)]

    static let empty = HandoffRendering(
        id: UUID(), text: NSAttributedString(), blocks: [], headingAnchors: [])

    func renderedRange(forAnchor anchor: String) -> NSRange? {
        headingAnchors.first(where: { $0.anchor == anchor })?.range
    }

    /// Maps a resolved snippet (UTF-16 range in the stripped markdown) to the
    /// rendered text: exact match inside the containing block when possible,
    /// otherwise the whole block.
    func renderedRange(forSourceRange source: Range<Int>, snippet: String) -> NSRange? {
        guard let block = blocks.first(where: {
            $0.sourceRange.lowerBound <= source.lowerBound
                && source.lowerBound < max($0.sourceRange.upperBound, $0.sourceRange.lowerBound + 1)
        }) ?? blocks.last(where: { $0.sourceRange.lowerBound <= source.lowerBound })
        else { return nil }
        let rendered = text.attributedSubstring(from: block.renderedRange).string as NSString
        let found = rendered.range(of: snippet)
        if found.location != NSNotFound {
            return NSRange(location: block.renderedRange.location + found.location, length: found.length)
        }
        return block.renderedRange
    }
}

enum HandoffTextBuilder {
    static let baseSize: CGFloat = 13
    static let axHeadingLevel = NSAttributedString.Key("AXHeadingLevel")

    static func build(document: HandoffDocument, scale: Double) -> HandoffRendering {
        let output = NSMutableAttributedString()
        var blocks: [HandoffRendering.RenderedBlock] = []
        var anchors: [(anchor: String, range: NSRange)] = []
        let scale = CGFloat(scale)

        for (index, block) in document.blocks.enumerated() {
            let start = output.length
            if block.isHeading {
                appendHeading(block, scale: scale, into: output)
            } else if isFencedCode(block.text) {
                appendCodeBlock(block.text, scale: scale, into: output)
            } else if isBlockquote(block.text) {
                appendBlockquote(block.text, scale: scale, into: output)
            } else if isList(block.text) {
                appendList(block.text, scale: scale, into: output)
            } else {
                appendParagraph(block.text, scale: scale, into: output)
            }
            let renderedRange = NSRange(location: start, length: output.length - start)
            blocks.append(
                HandoffRendering.RenderedBlock(
                    anchor: block.anchor, isHeading: block.isHeading,
                    sourceRange: block.range, sourceText: block.text,
                    renderedRange: renderedRange))
            if block.isHeading {
                anchors.append((block.anchor, renderedRange))
            }
            if index < document.blocks.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: baseSize * scale),
                    .foregroundColor: NSColor.labelColor,
                ]))
            }
        }
        return HandoffRendering(id: UUID(), text: output, blocks: blocks, headingAnchors: anchors)
    }

    // MARK: - Block shapes

    private static func isFencedCode(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0 == " " })
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isBlockquote(_ text: String) -> Bool {
        text.drop(while: { $0 == " " }).hasPrefix(">")
    }

    private static func isList(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.drop(while: { $0 == " " }) }
        guard let first = lines.first else { return false }
        return listMarker(String(first)) != nil
    }

    private static func listMarker(_ line: String) -> (marker: String, rest: String)? {
        if let match = line.firstMatch(of: /^([-*+])\s+(.*)$/) {
            return ("•", String(match.2))
        }
        if let match = line.firstMatch(of: /^(\d{1,4})[.)]\s+(.*)$/) {
            return ("\(match.1).", String(match.2))
        }
        return nil
    }

    private static func appendHeading(
        _ block: HandoffDocument.Block, scale: CGFloat, into output: NSMutableAttributedString
    ) {
        let level = block.level ?? 1
        let sizes: [CGFloat] = [24, 20, 16, 14, 13, 13]
        let size = sizes[min(max(level, 1), 6) - 1] * scale
        let title = block.headingPath.last ?? block.text
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 6 * scale
        style.paragraphSpacing = 4 * scale
        output.append(
            NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                    axHeadingLevel: level,
                ]))
    }

    private static func appendCodeBlock(
        _ text: String, scale: CGFloat, into output: NSMutableAttributedString
    ) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, isFencedCode(first) { lines.removeFirst() }
        if let last = lines.last, isFencedCode(last) { lines.removeLast() }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 12 * scale
        style.headIndent = 12 * scale
        style.paragraphSpacingBefore = 2 * scale
        output.append(
            NSAttributedString(
                string: lines.joined(separator: "\n"),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: (baseSize - 1) * scale, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.quaternarySystemFill,
                    .paragraphStyle: style,
                ]))
    }

    private static func appendBlockquote(
        _ text: String, scale: CGFloat, into output: NSMutableAttributedString
    ) {
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var trimmed = line.drop(while: { $0 == " " })
                if trimmed.hasPrefix(">") { trimmed = trimmed.dropFirst() }
                if trimmed.hasPrefix(" ") { trimmed = trimmed.dropFirst() }
                return String(trimmed)
            }
            .joined(separator: "\n")
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 14 * scale
        style.headIndent = 14 * scale
        appendInline(
            cleaned, scale: scale, into: output,
            baseColor: .secondaryLabelColor, paragraphStyle: style)
    }

    private static func appendList(
        _ text: String, scale: CGFloat, into output: NSMutableAttributedString
    ) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            let leading = line.prefix(while: { $0 == " " }).count
            let level = min(leading / 2, 4)
            let stripped = String(line.drop(while: { $0 == " " }))
            let style = NSMutableParagraphStyle()
            let indent = CGFloat(14 + level * 16) * scale
            style.firstLineHeadIndent = indent - 14 * scale
            style.headIndent = indent
            style.paragraphSpacing = 1 * scale
            if let (marker, rest) = listMarker(stripped) {
                output.append(
                    NSAttributedString(
                        string: "\(marker)  ",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: baseSize * scale),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: style,
                        ]))
                appendInline(rest, scale: scale, into: output, paragraphStyle: style)
            } else {
                appendInline(stripped, scale: scale, into: output, paragraphStyle: style)
            }
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
    }

    private static func appendParagraph(
        _ text: String, scale: CGFloat, into output: NSMutableAttributedString
    ) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2 * scale
        style.lineSpacing = 1.5 * scale
        appendInline(text, scale: scale, into: output, paragraphStyle: style)
    }

    // MARK: - Inline runs

    private struct InlineRun {
        var text: String
        var intent: InlinePresentationIntent
        var link: URL?
    }

    private static func appendInline(
        _ text: String, scale: CGFloat, into output: NSMutableAttributedString,
        baseColor: NSColor = .labelColor,
        paragraphStyle: NSParagraphStyle = NSParagraphStyle.default
    ) {
        let parsed = inlineMarkdown(text)
        var runs: [InlineRun] = []
        for run in parsed.runs {
            runs.append(
                InlineRun(
                    text: String(parsed.characters[run.range]),
                    intent: run.inlinePresentationIntent ?? [],
                    link: run.link))
        }
        var index = 0
        while index < runs.count {
            let run = runs[index]
            defer { index += 1 }
            if run.intent.contains(.code) {
                let followingText: String? =
                    index + 1 < runs.count && runs[index + 1].intent.isEmpty
                        && runs[index + 1].link == nil
                    ? runs[index + 1].text : nil
                if let reference = HandoffDocument.inlineFileReference(
                    code: run.text, following: followingText)
                {
                    // The " @sha" that follows the code span is hidden in the
                    // rendered text; the commit shows in the hover help tag.
                    if let sha = reference.sha, let followingText,
                        followingText.hasPrefix(" @\(sha)")
                    {
                        runs[index + 1].text = String(followingText.dropFirst(2 + sha.count))
                    }
                    let link = FileLink(
                        path: reference.path, line: reference.line,
                        endLine: reference.endLine, sha: reference.sha)
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: (baseSize - 1) * scale, weight: .medium),
                        .foregroundColor: NSColor.linkColor,
                        .toolTip: link.helpText,
                        .underlineStyle: 0,
                        .paragraphStyle: paragraphStyle,
                    ]
                    if let url = link.url {
                        attributes[.link] = url
                    }
                    output.append(NSAttributedString(string: link.pathWithLine, attributes: attributes))
                    continue
                }
            }
            appendPlainRun(
                run, scale: scale, into: output, baseColor: baseColor, paragraphStyle: paragraphStyle)
        }
    }

    private static func appendPlainRun(
        _ run: InlineRun, scale: CGFloat, into output: NSMutableAttributedString,
        baseColor: NSColor, paragraphStyle: NSParagraphStyle
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: baseColor,
            .paragraphStyle: paragraphStyle,
        ]
        if run.intent.contains(.code) {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: (baseSize - 1) * scale, weight: .regular)
            attributes[.backgroundColor] = NSColor.quaternarySystemFill
        } else {
            var font = NSFont.systemFont(ofSize: baseSize * scale)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if run.intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: baseSize * scale) ?? font
            }
            attributes[.font] = font
        }
        if run.intent.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.linkColor
        }
        output.append(NSAttributedString(string: run.text, attributes: attributes))
    }
}
