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
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasHandoffContent)
                    .help("Save the handoff as a Markdown file")
                Button("Close Session") { model.closeSession() }
                    .controlSize(.small)
                    .help("Put this session away and wait for the next Tuple call. It stays in History.")
            } else if model.sessionCanEnd {
                // Ending shouldn't depend on the Tuple call ending — a subtle,
                // always-visible control in the header, mirroring Session ▸
                // End Session… (⇧⌘E).
                Button(
                    model.snapshot.sessionState == .finalizing ? "Finish Session…" : "End Session…"
                ) {
                    model.confirmEndSession = true
                }
                .controlSize(.small)
                .help(
                    model.snapshot.sessionState == .finalizing
                        ? "Mark the handoff complete without waiting for the agent"
                        : "Tell the agent to stop following the call and finalize the handoff")
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
