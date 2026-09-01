import SwiftUI
import ChronicleKit

/// The right pane: the rendered planning handoff with its Plan-ready header.
struct HandoffPane: View {
    @Bindable var model: AppModel

    private var planReady: Bool {
        model.snapshot.mode == .complete || model.snapshot.mode == .interrupted
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body_
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Planning handoff")
                .font(.title3.weight(.semibold))
                .accessibilityHeading(.h2)
                .draggable(HandoffFileTransfer(markdown: model.snapshot.markdown))
                .help("Drag out a planning-handoff.md file")
            if planReady {
                Text("Plan ready")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                if model.snapshot.handoffSaved {
                    SavedPill()
                }
            } else {
                Text("Live notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Internal notes — notes.md")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .help(model.snapshot.notesPath ?? "")
            }
            Spacer()
            if planReady {
                Button("Copy") { model.copyHandoff() }
                    .controlSize(.small)
                    .disabled(!model.hasHandoffContent)
                    .help("Copy the handoff as Markdown and rich text")
                Button("Save As…") { model.saveHandoffAs() }
                    .controlSize(.small)
                    .disabled(!model.hasHandoffContent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Body

    @ViewBuilder
    private var body_: some View {
        if model.hasHandoffContent {
            HandoffTextView(
                rendering: model.rendering,
                command: model.handoffCommand,
                onOpenFile: { model.openFileReference($0) })
        } else {
            VStack(spacing: 4) {
                Text(emptyStateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyStateText: String {
        switch model.snapshot.mode {
        case .waitingTranscription:
            "Waiting for transcription"
        case .waitingClaude:
            "Waiting for the chronicle skill"
        case .finalizing:
            "Finalizing the plan"
        default:
            "No notes yet — the internal handoff will appear here as the chronicle skill writes it."
        }
    }
}

struct SavedPill: View {
    var body: some View {
        Text("Saved ✓")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.green.opacity(0.2), in: Capsule())
            .foregroundStyle(.green)
            .accessibilityLabel("Handoff saved")
    }
}
