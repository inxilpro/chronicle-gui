import SwiftUI
import ChronicleKit

/// The History window: recent sessions, opening terminal ones in the main
/// window, with delete confirmation and drag-out of unsaved handoffs.
struct HistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.historySortKey) private var sortKey = "startedAt"
    @AppStorage(SettingsKey.historySortAscending) private var sortAscending = false
    @State private var selection: SessionSummary.ID?
    @State private var pendingDelete: SessionSummary.ID?

    private var sessions: [SessionSummary] {
        let base = model.snapshot.sessions
        let sorted: [SessionSummary]
        switch sortKey {
        case "state":
            sorted = base.sorted { $0.state.rawValue < $1.state.rawValue }
        case "repo":
            sorted = base.sorted { repoName($0) < repoName($1) }
        default:
            sorted = base.sorted { $0.startedAt < $1.startedAt }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    var body: some View {
        Table(sessions, selection: $selection, sortOrder: sortBinding) {
            TableColumn("Session", value: \.repoSortKey) { session in
                HStack(spacing: 6) {
                    Text(repoName(session))
                        .fontWeight(.medium)
                    if session.hasUnsavedHandoff {
                        Text("Unsaved")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if session.dataPruned {
                        Text("Details expired")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .draggable(dragPayload(for: session))
                .accessibilityLabel(accessibilityLabel(session))
            }
            TableColumn("State", value: \.stateSortKey) { session in
                Text(session.state.displayName)
                    .foregroundStyle(session.state == .active ? Color.green : Color.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Started", value: \.startedAt) { session in
                Text(TimestampFormat.dateTime(session.startedAt))
            }
            .width(min: 130, ideal: 170)
        }
        .contextMenu(forSelectionType: SessionSummary.ID.self) { ids in
            if let id = ids.first {
                contextMenu(for: id)
            }
        } primaryAction: { ids in
            if let id = ids.first {
                open(id)
            }
        }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            open(selection)
            return .handled
        }
        .onDeleteCommand {
            guard let selection, canDelete(selection) else { return }
            pendingDelete = selection
        }
        .copyable(selection.map { [$0] } ?? [])
        .confirmationDialog(
            "Delete this Chronicle session and its internal handoff? Saved copies are not affected.",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    model.deleteSession(pendingDelete)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        }
        .navigationTitle("History")
        .frame(minWidth: 440, minHeight: 280)
    }

    private var sortBinding: Binding<[KeyPathComparator<SessionSummary>]> {
        Binding(
            get: {
                let comparator: KeyPathComparator<SessionSummary> =
                    switch sortKey {
                    case "state": KeyPathComparator(\.stateSortKey)
                    case "repo": KeyPathComparator(\.repoSortKey)
                    default: KeyPathComparator(\.startedAt)
                    }
                var result = comparator
                result.order = sortAscending ? .forward : .reverse
                return [result]
            },
            set: { comparators in
                guard let first = comparators.first else { return }
                sortAscending = first.order == .forward
                switch first.keyPath {
                case \SessionSummary.stateSortKey: sortKey = "state"
                case \SessionSummary.repoSortKey: sortKey = "repo"
                default: sortKey = "startedAt"
                }
            })
    }

    @ViewBuilder
    private func contextMenu(for id: SessionSummary.ID) -> some View {
        Button("Open") { open(id) }
        Button("Save Handoff As…") {
            model.openHistorySession(id)
            model.saveHandoffAs()
        }
        .disabled(!canSave(id))
        Button("Copy Call ID") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(id, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) {
            pendingDelete = id
        }
        .disabled(!canDelete(id))
    }

    private func open(_ id: SessionSummary.ID) {
        model.openHistorySession(id)
    }

    private func session(_ id: SessionSummary.ID) -> SessionSummary? {
        model.snapshot.sessions.first { $0.id == id }
    }

    private func canDelete(_ id: SessionSummary.ID) -> Bool {
        guard let session = session(id) else { return false }
        return session.state == .complete || session.state == .interrupted
    }

    private func canSave(_ id: SessionSummary.ID) -> Bool {
        guard let session = session(id) else { return false }
        return (session.state == .complete || session.state == .interrupted) && !session.dataPruned
    }

    private func repoName(_ session: SessionSummary) -> String {
        guard let repo = session.attachedRepo, !repo.isEmpty else { return session.id }
        return (repo as NSString).lastPathComponent
    }

    private func dragPayload(for session: SessionSummary) -> HandoffFileTransfer {
        HandoffFileTransfer(markdown: model.markdownForSession(session.id) ?? "")
    }

    private func accessibilityLabel(_ session: SessionSummary) -> String {
        "\(repoName(session)), \(session.state.displayName), \(TimestampFormat.dateTime(session.startedAt))"
    }
}

nonisolated extension SessionSummary {
    var repoSortKey: String {
        guard let repo = attachedRepo, !repo.isEmpty else { return id }
        return (repo as NSString).lastPathComponent
    }

    var stateSortKey: String { state.rawValue }
}
