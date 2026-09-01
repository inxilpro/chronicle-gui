import SwiftUI
import ChronicleKit

/// The left pane: Claude's review stream with banners, decision review, and
/// the source strip footer.
struct ReviewPane: View {
    @Bindable var model: AppModel
    @State private var nearBottom = true

    var body: some View {
        VStack(spacing: 0) {
            header
            banners
            idePicker
            feed
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Review")
                .font(.title3.weight(.semibold))
                .accessibilityHeading(.h2)
            Text(model.snapshot.mode == .complete ? "Session complete" : "Claude's stream")
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
                    EmptyView()
                }
            }
            if let text = modeBanner {
                Banner(icon: "clock", tint: .secondary) {
                    Text(text)
                } accessory: {
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var troubledSources: [SourceHealth] {
        model.snapshot.sources.filter {
            ["stopped", "error", "ambiguous"].contains($0.status)
        }
    }

    private var modeBanner: String? {
        switch model.snapshot.mode {
        case .waitingTranscription:
            "Call found. Waiting for transcription — start transcription in Tuple."
        case .waitingClaude:
            "Waiting for the chronicle skill to attach from a repository."
        case .finalizing:
            "Tuple call ended. Claude is finishing the handoff."
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
                Text("Multiple Chronicle sessions match this repository. Choose one:")
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
                        .contextMenu { contextMenu(for: message) }
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
                isStale: model.staleReferenceIDs.contains(message.id),
                onOpenReference: { model.openReference(message) })
        case .decision:
            DecisionRow(
                message: message,
                status: model.effectiveDecisionStatus(message) ?? .unreviewed,
                isPending: model.pendingReviews[message.id] != nil,
                pendingStatus: model.pendingReviews[message.id],
                isStale: model.staleReferenceIDs.contains(message.id),
                onApprove: { model.review(decisionId: message.id, as: .approved) },
                onReject: { model.review(decisionId: message.id, as: .rejected) },
                onOpenReference: { model.openReference(message) })
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
