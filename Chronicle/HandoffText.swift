import AppKit
import ChronicleKit
import Markdown

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

/// Renders the handoff as GitHub-flavored Markdown with GitHub-style
/// typography: heading scale with rules under h1/h2, filled code blocks,
/// bordered blockquotes, task lists, and real tables.
enum HandoffTextBuilder {
    static let baseSize: CGFloat = 13
    static let axHeadingLevel = NSAttributedString.Key("AXHeadingLevel")

    static func build(document: HandoffDocument, scale: Double) -> HandoffRendering {
        let output = NSMutableAttributedString()
        var blocks: [HandoffRendering.RenderedBlock] = []
        var anchors: [(anchor: String, range: NSRange)] = []
        let renderer = Renderer(scale: CGFloat(scale))

        for block in document.blocks {
            let start = output.length
            renderer.render(blockText: block.text, into: output)
            let renderedRange = NSRange(location: start, length: output.length - start)
            blocks.append(
                HandoffRendering.RenderedBlock(
                    anchor: block.anchor, isHeading: block.isHeading,
                    sourceRange: block.range, sourceText: block.text,
                    renderedRange: renderedRange))
            if block.isHeading {
                anchors.append((block.anchor, renderedRange))
            }
        }
        return HandoffRendering(id: UUID(), text: output, blocks: blocks, headingAnchors: anchors)
    }
}

/// One rendering pass; holds the scale and the GitHub-flavored style palette.
private final class Renderer {
    let scale: CGFloat

    init(scale: CGFloat) {
        self.scale = scale
    }

    private var base: CGFloat { HandoffTextBuilder.baseSize * scale }

    // GitHub's type scale relative to its 16px body, applied to the app's base.
    private func headingSize(_ level: Int) -> CGFloat {
        let ratios: [CGFloat] = [2.0, 1.5, 1.25, 1.0, 0.875, 0.85]
        return base * ratios[min(max(level, 1), 6) - 1]
    }

    private var codeBackground: NSColor { .quaternarySystemFill }
    private var rule: NSColor { .separatorColor }

    // MARK: - Inline state

    private struct InlineContext {
        var size: CGFloat
        var bold = false
        var italic = false
        var strikethrough = false
        var link: URL?
        var color: NSColor = .labelColor
    }

    /// Everything that positions a run's paragraph: indents, spacing, and the
    /// text blocks (code fill, quote bar, table cell) it belongs to.
    private struct BlockContext {
        var style: NSMutableParagraphStyle
        var extra: [NSAttributedString.Key: Any] = [:]

        init(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) {
            style = NSMutableParagraphStyle()
            configure(style)
        }
    }

    // MARK: - Top level

    func render(blockText: String, into output: NSMutableAttributedString) {
        let parsed = Document(parsing: blockText)
        for child in parsed.children {
            render(markup: child, depth: 0, into: output)
        }
    }

    private func render(markup: Markup, depth: Int, into output: NSMutableAttributedString) {
        switch markup {
        case let heading as Heading:
            renderHeading(heading, into: output)
        case let paragraph as Paragraph:
            renderParagraph(paragraph, into: output)
        case let code as CodeBlock:
            renderCodeBlock(code, into: output)
        case let quote as BlockQuote:
            renderBlockquote(quote, depth: depth, into: output)
        case let list as UnorderedList:
            renderList(items: Array(list.listItems), ordered: false, start: 1, depth: depth, into: output)
        case let list as OrderedList:
            renderList(items: Array(list.listItems), ordered: true, start: Int(list.startIndex), depth: depth, into: output)
        case let table as Markdown.Table:
            renderTable(table, into: output)
        case is ThematicBreak:
            renderThematicBreak(into: output)
        case let html as HTMLBlock:
            renderVerbatim(html.rawHTML, into: output)
        default:
            // Anything unhandled renders as its plain text rather than vanishing.
            renderVerbatim(markup.format(), into: output)
        }
    }

    // MARK: - Blocks

    private func renderHeading(_ heading: Heading, into output: NSMutableAttributedString) {
        let level = heading.level
        var block = BlockContext { style in
            style.paragraphSpacingBefore = 14 * self.scale
            style.paragraphSpacing = 8 * self.scale
        }
        if level <= 2 {
            let border = NSTextBlock()
            border.setBorderColor(rule)
            border.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            border.setWidth(4 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
            border.setContentWidth(100, type: .percentageValueType)
            block.style.textBlocks = [border]
        }
        block.extra[HandoffTextBuilder.axHeadingLevel] = level
        var context = InlineContext(size: headingSize(level))
        context.bold = true
        if level == 6 {
            context.color = .secondaryLabelColor
        }
        renderInlineChildren(of: heading, context: context, block: block, into: output)
        terminateParagraph(block: block, context: context, into: output)
    }

    private func renderParagraph(_ paragraph: Paragraph, into output: NSMutableAttributedString) {
        let block = BlockContext { style in
            style.paragraphSpacing = 10 * self.scale
            style.lineSpacing = 2.5 * self.scale
        }
        let context = InlineContext(size: base)
        renderInlineChildren(of: paragraph, context: context, block: block, into: output)
        terminateParagraph(block: block, context: context, into: output)
    }

    private func renderCodeBlock(_ code: CodeBlock, into output: NSMutableAttributedString) {
        let fill = NSTextBlock()
        fill.backgroundColor = codeBackground
        fill.setContentWidth(100, type: .percentageValueType)
        fill.setWidth(10 * scale, type: .absoluteValueType, for: .padding)
        fill.setWidth(6 * scale, type: .absoluteValueType, for: .margin, edge: .minY)
        fill.setWidth(6 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        let block = BlockContext { style in
            style.textBlocks = [fill]
            style.lineSpacing = 1.5 * self.scale
        }
        let attributes = attributes(
            for: InlineContext(size: base * 0.85), monospaced: true, block: block)
        var text = code.code
        while text.hasSuffix("\n") {
            text.removeLast()
        }
        output.append(NSAttributedString(string: text + "\n", attributes: attributes))
    }

    private func renderBlockquote(_ quote: BlockQuote, depth: Int, into output: NSMutableAttributedString) {
        let bar = NSTextBlock()
        bar.setBorderColor(rule)
        bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setWidth(12 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
        bar.setContentWidth(100, type: .percentageValueType)
        for child in quote.children {
            if let paragraph = child as? Paragraph {
                let block = BlockContext { style in
                    style.textBlocks = [bar]
                    style.paragraphSpacing = 6 * self.scale
                    style.lineSpacing = 2.5 * self.scale
                }
                var context = InlineContext(size: base)
                context.color = .secondaryLabelColor
                renderInlineChildren(of: paragraph, context: context, block: block, into: output)
                terminateParagraph(block: block, context: context, into: output)
            } else {
                render(markup: child, depth: depth + 1, into: output)
            }
        }
    }

    private func renderList(
        items: [ListItem], ordered: Bool, start: Int, depth: Int,
        into output: NSMutableAttributedString
    ) {
        for (offset, item) in items.enumerated() {
            let markerText: String
            if let checkbox = item.checkbox {
                markerText = checkbox == .checked ? "☑" : "☐"
            } else if ordered {
                markerText = "\(start + offset)."
            } else {
                markerText = ["•", "◦", "▪"][min(depth, 2)]
            }
            let indent = CGFloat(depth) * 20 * scale
            let block = BlockContext { style in
                style.firstLineHeadIndent = indent + 4 * self.scale
                style.headIndent = indent + 22 * self.scale
                style.paragraphSpacing = 3 * self.scale
                style.lineSpacing = 2 * self.scale
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22 * self.scale)]
                style.defaultTabInterval = 22 * self.scale
            }
            var context = InlineContext(size: base)
            var markerAttributes = attributes(for: context, monospaced: false, block: block)
            markerAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            output.append(NSAttributedString(string: "\(markerText)\t", attributes: markerAttributes))
            if item.checkbox == .checked {
                context.strikethrough = false
            }
            var closedParagraph = false
            for (index, child) in item.children.enumerated() {
                if index == 0, let paragraph = child as? Paragraph {
                    renderInlineChildren(of: paragraph, context: context, block: block, into: output)
                    terminateParagraph(block: block, context: context, into: output)
                    closedParagraph = true
                } else {
                    if !closedParagraph {
                        terminateParagraph(block: block, context: context, into: output)
                        closedParagraph = true
                    }
                    render(markup: child, depth: depth + 1, into: output)
                }
            }
            if !closedParagraph {
                terminateParagraph(block: block, context: context, into: output)
            }
        }
    }

    private func renderTable(_ table: Markdown.Table, into output: NSMutableAttributedString) {
        let columns = table.maxColumnCount
        guard columns > 0 else { return }
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.setContentWidth(100, type: .percentageValueType)

        func alignment(_ column: Int) -> NSTextAlignment {
            guard column < table.columnAlignments.count else { return .left }
            switch table.columnAlignments[column] {
            case .center: return .center
            case .right: return .right
            default: return .left
            }
        }

        func appendCell(
            _ cell: Markdown.Table.Cell, row: Int, column: Int, isHeader: Bool
        ) {
            let cellBlock = NSTextTableBlock(
                table: textTable, startingRow: row, rowSpan: 1,
                startingColumn: column, columnSpan: max(Int(cell.colspan), 1))
            cellBlock.setBorderColor(rule)
            cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
            cellBlock.setWidth(6 * scale, type: .absoluteValueType, for: .padding)
            if isHeader {
                cellBlock.backgroundColor = codeBackground
            }
            let block = BlockContext { style in
                style.textBlocks = [cellBlock]
                style.alignment = alignment(column)
            }
            var context = InlineContext(size: base)
            context.bold = isHeader
            renderInlineChildren(of: cell, context: context, block: block, into: output)
            terminateParagraph(block: block, context: context, into: output)
        }

        var row = 0
        for (column, cell) in table.head.cells.enumerated() {
            appendCell(cell, row: row, column: column, isHeader: true)
        }
        row += 1
        for bodyRow in table.body.rows {
            for (column, cell) in bodyRow.cells.enumerated() {
                appendCell(cell, row: row, column: column, isHeader: false)
            }
            row += 1
        }
    }

    private func renderThematicBreak(into output: NSMutableAttributedString) {
        let bar = NSTextBlock()
        bar.backgroundColor = rule
        bar.setContentWidth(100, type: .percentageValueType)
        bar.setWidth(8 * scale, type: .absoluteValueType, for: .margin, edge: .minY)
        bar.setWidth(8 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        let block = BlockContext { style in
            style.textBlocks = [bar]
            style.maximumLineHeight = 3
        }
        let attributes = attributes(for: InlineContext(size: 2), monospaced: false, block: block)
        output.append(NSAttributedString(string: "\u{00A0}\n", attributes: attributes))
    }

    private func renderVerbatim(_ text: String, into output: NSMutableAttributedString) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let block = BlockContext { style in
            style.paragraphSpacing = 10 * self.scale
        }
        var context = InlineContext(size: base)
        context.color = .secondaryLabelColor
        let attributes = attributes(for: context, monospaced: false, block: block)
        output.append(NSAttributedString(string: trimmed + "\n", attributes: attributes))
    }

    // MARK: - Inline rendering

    private func renderInlineChildren(
        of parent: Markup, context: InlineContext, block: BlockContext,
        into output: NSMutableAttributedString
    ) {
        let children = Array(parent.children)
        var skipPrefixOfNext = 0
        for (index, child) in children.enumerated() {
            if skipPrefixOfNext > 0, let text = child as? Markdown.Text {
                let remainder = String(text.string.dropFirst(skipPrefixOfNext))
                skipPrefixOfNext = 0
                appendText(remainder, context: context, block: block, into: output)
                continue
            }
            skipPrefixOfNext = 0
            switch child {
            case let text as Markdown.Text:
                appendText(text.string, context: context, block: block, into: output)
            case is SoftBreak:
                appendText(" ", context: context, block: block, into: output)
            case is LineBreak:
                appendText("\n", context: context, block: block, into: output)
            case let code as InlineCode:
                let following = (children.indices.contains(index + 1)
                    ? children[index + 1] as? Markdown.Text : nil)?.string
                skipPrefixOfNext = appendInlineCode(
                    code.code, following: following, context: context, block: block, into: output)
            case let strong as Strong:
                var nested = context
                nested.bold = true
                renderInlineChildren(of: strong, context: nested, block: block, into: output)
            case let emphasis as Emphasis:
                var nested = context
                nested.italic = true
                renderInlineChildren(of: emphasis, context: nested, block: block, into: output)
            case let strikethrough as Strikethrough:
                var nested = context
                nested.strikethrough = true
                renderInlineChildren(of: strikethrough, context: nested, block: block, into: output)
            case let link as Markdown.Link:
                var nested = context
                nested.link = link.destination.flatMap(URL.init(string:))
                nested.color = .linkColor
                renderInlineChildren(of: link, context: nested, block: block, into: output)
            case let image as Markdown.Image:
                appendText(image.plainText, context: context, block: block, into: output)
            case let html as InlineHTML:
                appendText(html.rawHTML, context: context, block: block, into: output)
            default:
                appendText(child.format(), context: context, block: block, into: output)
            }
        }
    }

    private func appendText(
        _ text: String, context: InlineContext, block: BlockContext,
        into output: NSMutableAttributedString
    ) {
        guard !text.isEmpty else { return }
        let attributes = attributes(for: context, monospaced: false, block: block)
        output.append(NSAttributedString(string: text, attributes: attributes))
    }

    /// Renders one inline code span. When the span plus the text following it
    /// form a file reference (`path[:line]` @sha), it becomes an editor link
    /// with the SHA hidden behind the hover help tag; returns how many
    /// characters of the following text were consumed.
    private func appendInlineCode(
        _ code: String, following: String?, context: InlineContext, block: BlockContext,
        into output: NSMutableAttributedString
    ) -> Int {
        if let reference = HandoffDocument.inlineFileReference(code: code, following: following) {
            let link = FileLink(
                path: reference.path, line: reference.line,
                endLine: reference.endLine, sha: reference.sha)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: context.size * 0.85, bold: true, italic: false, monospaced: true),
                .foregroundColor: NSColor.linkColor,
                .toolTip: link.helpText,
                .underlineStyle: 0,
                .paragraphStyle: block.style,
            ]
            for (key, value) in block.extra {
                attributes[key] = value
            }
            if let url = link.url {
                attributes[.link] = url
            }
            output.append(NSAttributedString(string: link.pathWithLine, attributes: attributes))
            if let sha = reference.sha, let following, following.hasPrefix(" @\(sha)") {
                return 2 + sha.count
            }
            return 0
        }
        var attributes = attributes(for: context, monospaced: true, block: block)
        attributes[.backgroundColor] = codeBackground
        attributes[.font] = font(
            size: context.size * 0.85, bold: context.bold, italic: context.italic, monospaced: true)
        output.append(NSAttributedString(string: code, attributes: attributes))
        return 0
    }

    /// Ends the current paragraph with a newline carrying the same paragraph
    /// style, so text blocks (fills, borders, table cells) close correctly.
    private func terminateParagraph(
        block: BlockContext, context: InlineContext, into output: NSMutableAttributedString
    ) {
        let attributes = attributes(for: context, monospaced: false, block: block)
        output.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    // MARK: - Attributes

    private func attributes(
        for context: InlineContext, monospaced: Bool, block: BlockContext
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(
                size: monospaced ? context.size * 0.85 : context.size,
                bold: context.bold, italic: context.italic, monospaced: monospaced),
            .foregroundColor: context.color,
            .paragraphStyle: block.style,
        ]
        if context.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = context.link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.linkColor
        }
        for (key, value) in block.extra {
            attributes[key] = value
        }
        return attributes
    }

    private func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> NSFont {
        var font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
            : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }
}
