import AppKit
import ChronicleKit
import SwiftUI

/// The rendered handoff body, bridged to NSTextView for native selection,
/// the system find bar (⌘F/⌘G), per-range tooltips on file references, and
/// precise scroll anchoring across live re-renders.
struct HandoffTextView: NSViewRepresentable {
    var rendering: HandoffRendering
    var command: HandoffViewCommand?
    var onOpenFile: (FileLink) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.displaysLinkToolTips = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Planning handoff")
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.apply(rendering, preservingScroll: false)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenFile = onOpenFile
        if coordinator.renderingID != rendering.id {
            coordinator.apply(rendering, preservingScroll: true)
        }
        if let command, coordinator.lastCommandID != command.id {
            coordinator.lastCommandID = command.id
            coordinator.perform(command)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        var onOpenFile: ((FileLink) -> Void)?
        var renderingID: UUID?
        var lastCommandID: UUID?
        private var rendering = HandoffRendering.empty

        private var textView: NSTextView? {
            scrollView?.documentView as? NSTextView
        }

        // MARK: - Content updates with scroll anchoring

        func apply(_ new: HandoffRendering, preservingScroll: Bool) {
            guard let textView, let scrollView else { return }
            let anchor = preservingScroll ? currentAnchor() : nil
            renderingID = new.id
            let old = rendering
            rendering = new
            textView.textStorage?.setAttributedString(new.text)
            guard let anchor, old.text.length > 0 else { return }
            restore(anchor: anchor, in: scrollView)
        }

        /// (nearest preceding heading anchor, character offset past it, y offset
        /// of that character from the top of the visible rect).
        private struct ScrollAnchor {
            var headingAnchor: String?
            var characterOffset: Int
            var yOffset: CGFloat
        }

        private func currentAnchor() -> ScrollAnchor? {
            guard let textView, let scrollView,
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer,
                textView.textStorage?.length ?? 0 > 0
            else { return nil }
            let visible = scrollView.contentView.bounds
            let point = NSPoint(
                x: textView.textContainerInset.width + 1,
                y: max(visible.minY - textView.textContainerInset.height, 0) + 1)
            let glyph = layoutManager.glyphIndex(for: point, in: container)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            let rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let heading = rendering.headingAnchors.last { $0.range.location <= character }
            let base = heading?.range.location ?? 0
            return ScrollAnchor(
                headingAnchor: heading?.anchor,
                characterOffset: character - base,
                yOffset: rect.minY + textView.textContainerInset.height - visible.minY)
        }

        private func restore(anchor: ScrollAnchor, in scrollView: NSScrollView) {
            guard let textView, let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else { return }
            let base: Int
            var limit = rendering.text.length
            if let headingAnchor = anchor.headingAnchor,
                let index = rendering.headingAnchors.firstIndex(where: { $0.anchor == headingAnchor })
            {
                base = rendering.headingAnchors[index].range.location
                if index + 1 < rendering.headingAnchors.count {
                    limit = rendering.headingAnchors[index + 1].range.location
                }
            } else if anchor.headingAnchor != nil {
                return  // The section is gone; keep the default scroll position.
            } else {
                base = 0
                limit = rendering.headingAnchors.first?.range.location ?? rendering.text.length
            }
            let character = min(base + anchor.characterOffset, max(limit - 1, base))
            guard character < rendering.text.length else { return }
            layoutManager.ensureLayout(for: container)
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            let rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let target = max(rect.minY + textView.textContainerInset.height - anchor.yOffset, 0)
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: - Commands

        func perform(_ command: HandoffViewCommand) {
            guard let textView else { return }
            switch command.kind {
            case .find:
                performFinder(.showFindInterface, on: textView)
            case .findNext:
                performFinder(.nextMatch, on: textView)
            case .findPrevious:
                performFinder(.previousMatch, on: textView)
            case .scrollTo(let range):
                reveal(range: range, on: textView)
            case .scrollToAnchor(let anchor):
                if let range = rendering.renderedRange(forAnchor: anchor) {
                    reveal(range: range, on: textView)
                }
            }
        }

        private func reveal(range: NSRange, on textView: NSTextView) {
            guard NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
            textView.window?.makeFirstResponder(textView)
            textView.scrollRangeToVisible(range)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                textView.setSelectedRange(range)
            } else {
                textView.showFindIndicator(for: range)
            }
        }

        private func performFinder(_ action: NSTextFinder.Action, on textView: NSTextView) {
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = action.rawValue
            textView.performTextFinderAction(item)
        }

        // MARK: - Context-menu helpers

        fileprivate func fileLink(at characterIndex: Int, in textView: NSTextView) -> FileLink? {
            guard let storage = textView.textStorage, characterIndex < storage.length else {
                return nil
            }
            guard
                let url = storage.attribute(.link, at: characterIndex, effectiveRange: nil) as? URL
            else { return nil }
            return FileLink(url: url)
        }

        /// Copy as Markdown copies the comment-stripped source text of every
        /// block intersecting the selection (the whole document when there is
        /// no selection).
        fileprivate func markdown(forSelectionIn textView: NSTextView) -> String {
            let selection = textView.selectedRange()
            let intersecting: [HandoffRendering.RenderedBlock]
            if selection.length == 0 {
                intersecting = rendering.blocks
            } else {
                intersecting = rendering.blocks.filter {
                    NSIntersectionRange($0.renderedRange, selection).length > 0
                }
            }
            return intersecting.map(\.sourceText).joined(separator: "\n\n")
        }
    }
}

extension HandoffTextView.Coordinator: NSTextViewDelegate {
    nonisolated func textView(
        _ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int
    ) -> Bool {
        MainActor.assumeIsolated {
            guard let url = link as? URL, let fileLink = FileLink(url: url) else {
                return false
            }
            onOpenFile?(fileLink)
            return true
        }
    }

    nonisolated func textView(
        _ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int
    ) -> NSMenu? {
        MainActor.assumeIsolated {
            augment(menu, view: view, characterIndex: Int(charIndex))
        }
        return menu
    }

    private func augment(_ menu: NSMenu, view: NSTextView, characterIndex: Int) {
        if let link = fileLink(at: characterIndex, in: view) {
            var index = 0
            let open = NSMenuItem(title: "Open in Editor", action: nil, keyEquivalent: "")
            setHandler(open) { [weak self] in self?.onOpenFile?(link) }
            menu.insertItem(open, at: index)
            index += 1
            let copyPath = NSMenuItem(title: "Copy Path", action: nil, keyEquivalent: "")
            setHandler(copyPath) { Self.copyToPasteboard(link.path) }
            menu.insertItem(copyPath, at: index)
            index += 1
            let copyLine = NSMenuItem(
                title: "Copy Path with Line", action: nil, keyEquivalent: "")
            setHandler(copyLine) { Self.copyToPasteboard(link.pathWithLine) }
            menu.insertItem(copyLine, at: index)
            index += 1
            menu.insertItem(.separator(), at: index)
        }
        let copyMarkdown = NSMenuItem(title: "Copy as Markdown", action: nil, keyEquivalent: "")
        let markdown = markdown(forSelectionIn: view)
        setHandler(copyMarkdown) { Self.copyToPasteboard(markdown) }
        copyMarkdown.isEnabled = !markdown.isEmpty
        menu.addItem(.separator())
        menu.addItem(copyMarkdown)
    }

    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func setHandler(_ item: NSMenuItem, _ handler: @escaping @MainActor () -> Void) {
        let target = MenuAction(handler: handler)
        item.target = target
        item.action = #selector(MenuAction.fire)
        item.representedObject = target
    }
}

/// Retained via `representedObject` so ad-hoc context-menu items can carry a closure.
@MainActor
private final class MenuAction: NSObject {
    let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}
