import SwiftUI
import ChronicleKit

/// The left pane: Claude's review stream with banners, decision review, and
/// the source strip footer.
struct ReviewPane: View {
    @Bindable var model: AppModel
    @State private var nearBottom = true
    @State private var feedScrolled = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                banners
                idePicker
            }
            .zIndex(1)
            feed
                .overlay(alignment: .top) { headerShadow }
            Divider()
            footer
        }
    }

    /// Casts a soft edge under the header block once the list has scrolled,
    /// separating it from rows passing beneath.
    private var headerShadow: some View {
        LinearGradient(
            colors: [.black.opacity(0.14), .black.opacity(0)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 5)
        .opacity(feedScrolled ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: feedScrolled)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Review")
                .font(.title3.weight(.semibold))
                .accessibilityHeading(.h2)
            Text(model.snapshot.mode == .complete ? "Session complete" : "Agent stream")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let label = FeedFormat.unreadLabel(model.unreadCount) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(model.unreadCount) unread")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Banners (stacked, in priority order)

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 6) {
            if !model.snapshot.integrationInstalled {
                Banner(icon: "puzzlepiece.extension", tint: .orange) {
                    Text("The Claude integration is not installed, so the chronicle skill cannot follow this call.")
                } accessory: {
                    Button("Install") { model.installIntegration() }
                        .controlSize(.small)
                }
            } else if model.integrationNeedsUpdate {
                Banner(icon: "puzzlepiece.extension", tint: .orange) {
                    Text("This version of Chronicle ships a newer chronicle skill than the one installed.")
                } accessory: {
                    Button("Update") { model.installIntegration() }
                        .controlSize(.small)
                }
            }
            if !model.snapshot.ideRegistryFound {
                Banner(icon: "folder.badge.questionmark", tint: .secondary) {
                    Text("No Chronicle IDE data at \(model.snapshot.ideRoot).")
                } accessory: {
                    Button("Choose Chronicle Folder…") { model.chooseIDEFolder() }
                        .controlSize(.small)
                }
            }
            if let warning = model.collectorWarning {
                Banner(icon: "exclamationmark.triangle", tint: .orange) {
                    Text(warning)
                } accessory: {
                    Button {
                        model.dismissCollectorWarning()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss warning")
                }
            }
            ForEach(troubledSources, id: \.source) { source in
                Banner(
                    icon: source.status == "error"
                        ? "exclamationmark.circle" : "pause.circle",
                    tint: source.statusValue?.tint ?? .orange
                ) {
                    Text("\(source.displayName): \(source.detail ?? source.label)")
                } accessory: {
                    if source.source == SourceName.tuple, source.status == "stopped",
                        model.snapshot.sessionState == .active
                    {
                        Button("End Session…") { model.confirmEndSession = true }
                            .controlSize(.small)
                            .help("Finalize now if the call is actually over")
                    }
                }
            }
            if let text = modeBanner {
                Banner(icon: "clock", tint: .secondary) {
                    if model.snapshot.mode == .waitingClaude {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(text)
                            SessionPromptField()
                        }
                    } else {
                        Text(text)
                    }
                } accessory: {
                    if model.snapshot.mode == .finalizing {
                        Button("Finish Session…") { model.confirmEndSession = true }
                            .controlSize(.small)
                            .help("Mark the handoff complete without waiting for the agent")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var troubledSources: [SourceHealth] {
        model.snapshot.sources.filter {
            ["stopped", "error", "ambiguous"].contains($0.status)
                // The dismissible collector warning above already shows this
                // exact message; don't stack it twice.
                && $0.detail != model.collectorWarning
        }
    }

    private var modeBanner: String? {
        switch model.snapshot.mode {
        case .waitingTranscription:
            "Call found. Waiting for transcription — start transcription in Tuple."
        case .waitingClaude:
            "Waiting for the chronicle skill to attach from a repository."
        case .finalizing:
            "Tuple call ended. The agent is finishing the handoff."
        case .interrupted:
            "This session was interrupted. Review or save the handoff, then delete it when no longer needed."
        default:
            nil
        }
    }

    // MARK: - IDE session picker

    @ViewBuilder
    private var idePicker: some View {
        let candidates = model.snapshot.ideCandidates
        if candidates.count > 1, model.source(SourceName.chronicle)?.status == "ambiguous" {
            VStack(alignment: .leading, spacing: 6) {
                Text("Multiple IDE sessions match this repository. Choose one:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    Button {
                        model.selectIDECandidate(candidate.id)
                    } label: {
                        HStack {
                            Text(candidate.projectName)
                                .fontWeight(.medium)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("started \(TimestampFormat.dateTime(candidate.startedAt))")
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(candidate.state.rawValue)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        "\(candidate.projectName), started \(TimestampFormat.dateTime(candidate.startedAt)), \(candidate.state.rawValue)")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Feed

    private var feed: some View {
        ScrollViewReader { proxy in
            List(selection: $model.feedSelection) {
                ForEach(model.snapshot.messages) { message in
                    row(for: message)
                        .id(message.id)
                        .tag(message.id)
                        .listRowSeparator(.hidden)
                        // Rows draw their own accent outline when selected; the
                        // platform full-background highlight stays off.
                        .listRowBackground(Color.clear)
                        .selectionDisabled(message.kind == .ack)
                        .contextMenu { contextMenu(for: message) }
                }
                if model.agentIsWorking {
                    TypingIndicatorRow()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
                Color.clear
                    .frame(height: 1)
                    .id("feed-bottom")
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .onAppear { nearBottom = true }
                    .onDisappear { nearBottom = false }
            }
            .listStyle(.plain)
            // listRowBackground(.clear) alone doesn't stop the backing
            // NSTableView from flashing its own selection under the rows.
            .background(FeedSelectionHighlightDisabler())
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, isScrolled in
                feedScrolled = isScrolled
            }
            .accessibilityLabel("Review stream")
            .copyable(copyableSelection)
            .onKeyPress(.space) { toggleReadOnSelection() }
            .onKeyPress(.return) { approveSelection() }
            .onDeleteCommand { rejectSelection() }
            .overlay { emptyState }
            .onChange(of: model.snapshot.messages.count) {
                if nearBottom {
                    proxy.scrollTo("feed-bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.agentIsWorking) {
                if model.agentIsWorking, nearBottom {
                    proxy.scrollTo("feed-bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.feedScrollTarget) {
                guard let target = model.feedScrollTarget else { return }
                model.feedScrollTarget = nil
                model.feedSelection = target
                withAnimation {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for message: ChatMessage) -> some View {
        switch message.kind {
        case .ack:
            AckRow(message: message)
        case .message:
            MessageRow(
                message: message,
                isSelected: model.feedSelection == message.id,
                isStale: model.staleReferenceIDs.contains(message.id),
                onOpenReference: { model.openReference(message) })
        case .decision:
            DecisionRow(
                message: message,
                status: model.effectiveDecisionStatus(message) ?? .unreviewed,
                isSelected: model.feedSelection == message.id,
                onApprove: { model.review(decisionId: message.id, as: .approved) },
                onReject: { model.review(decisionId: message.id, as: .rejected) })
        }
    }

    @ViewBuilder
    private func contextMenu(for message: ChatMessage) -> some View {
        Button("Copy Message") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(message.text, forType: .string)
        }
        if message.kind != .ack, !message.read {
            Button("Mark as Read") { model.markRead(message.id) }
        }
        if message.kind == .decision, model.effectiveDecisionStatus(message) == .unreviewed {
            Divider()
            Button("Approve Decision") { model.review(decisionId: message.id, as: .approved) }
            Button("Reject Decision") { model.review(decisionId: message.id, as: .rejected) }
        }
        if let reference = message.reference {
            Divider()
            if !model.staleReferenceIDs.contains(message.id) {
                Button("Jump to Section") { model.openReference(message) }
            }
            Button("Copy Reference") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(
                    FeedFormat.referencePasteboardText(reference), forType: .string)
            }
        }
    }

    private var copyableSelection: [String] {
        guard let message = model.selectedMessage else { return [] }
        return [message.text]
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.snapshot.messages.isEmpty {
            VStack(spacing: 4) {
                Text("You're all caught up")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("New review notes and decisions will appear here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Keyboard

    private func toggleReadOnSelection() -> KeyPress.Result {
        guard let message = model.selectedMessage, message.kind != .ack, !message.read else {
            return .ignored
        }
        model.markRead(message.id)
        return .handled
    }

    private func approveSelection() -> KeyPress.Result {
        guard let decision = model.selectedUnreviewedDecision else { return .ignored }
        model.review(decisionId: decision.id, as: .approved)
        return .handled
    }

    private func rejectSelection() {
        guard let decision = model.selectedUnreviewedDecision else { return }
        model.review(decisionId: decision.id, as: .rejected)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            SourceStrip(sources: model.snapshot.sources)
            Spacer()
            Button {
                model.markAllRead()
            } label: {
                if model.unreadCount > 0 {
                    Text("Mark All as Read (\(model.unreadCount))")
                } else {
                    Text("Mark All as Read")
                }
            }
            .controlSize(.small)
            .disabled(model.unreadCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// SwiftUI's List on macOS is backed by an NSTableView that draws its own
/// selection (blue while clicking, gray at rest) behind the rows even with a
/// clear `listRowBackground`. The feed's rows draw their own accent outline
/// instead, so the platform highlight is switched off at the AppKit level.
/// Finding no table view (a future SwiftUI-native List) changes nothing.
private struct FeedSelectionHighlightDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Locator() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Locator: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The List's platform views are siblings installed around the
            // same time; defer one runloop turn so they exist.
            DispatchQueue.main.async { [weak self] in
                self?.disableHighlight()
            }
        }

        private func disableHighlight() {
            var ancestor = superview
            var depth = 0
            while let view = ancestor, depth < 8 {
                if let table = Self.findTableView(in: view) {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
                depth += 1
            }
        }

        private static func findTableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = findTableView(in: subview) { return table }
            }
            return nil
        }
    }
}

/// A compact stacked banner row.
struct Banner<Content: View, Accessory: View>: View {
    var icon: String
    var tint: Color
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .imageScale(.small)
                .accessibilityHidden(true)
            content()
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
