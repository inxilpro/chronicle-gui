import AppKit
import ChronicleKit
import SwiftUI

/// Centered guidance shown when there is no session (`waitingCall`).
struct WaitingView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Keeps the install button visible as confirmation after a click, rather
    /// than letting it vanish the moment the install lands.
    @State private var installRequested = false

    private var callAvailable: Bool {
        model.snapshot.availableCallId != nil
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Tuple call companion")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(1)
                .foregroundStyle(.tertiary)
            Text(callAvailable ? "Tuple call detected" : "Waiting for a Tuple call")
                .font(.title.weight(.semibold))
                .accessibilityHeading(.h1)
            Text(
                callAvailable
                    ? "Start a session to have Chronicle follow this call. Start transcription in Tuple when you're ready."
                    : "Join a call in Tuple, then start a session. Chronicle won't follow a call until you do."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            SourceStrip(sources: model.snapshot.sources)
                .padding(.top, 4)

            if let error = model.tupleDiscoveryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.leading)
            }

            Button("Start Session") {
                model.startSession()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!callAvailable)
            .help(callAvailable ? "Follow the current Tuple call" : "Join a Tuple call first")
            .padding(.top, 6)

            if !model.snapshot.integrationInstalled {
                Button("Install Claude Integration") {
                    installRequested = true
                    model.installIntegration()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else if model.integrationNeedsUpdate {
                VStack(spacing: 6) {
                    Text("This version of Chronicle ships a newer chronicle skill than the one installed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Update Claude Integration") {
                        installRequested = true
                        model.installIntegration()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else if installRequested {
                Button {
                } label: {
                    Label("Skill Installed", systemImage: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(true)
                .accessibilityLabel("Claude integration installed")
            }

            if model.snapshot.integrationInstalled {
                VStack(spacing: 6) {
                    Text("Once you're on the call, send Claude Code this prompt from the repository being planned:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    SessionPromptField()
                }
                .padding(.top, 10)
            }

            if !model.snapshot.ideRegistryFound {
                HStack(spacing: 4) {
                    Text("Chronicle IDE data was not found at \(model.snapshot.ideRoot).")
                        .foregroundStyle(.secondary)
                    Button("Choose Chronicle Folder…") {
                        model.chooseIDEFolder()
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .padding(.top, 8)
            }

            if !model.snapshot.sessions.isEmpty {
                HStack(spacing: 4) {
                    Text("Notes from earlier calls are in History.")
                        .foregroundStyle(.secondary)
                    Button("Open History") {
                        openWindow(id: "history")
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The session-start prompt with a click-to-copy affordance, shown on the
/// waiting screen and in the waiting-for-Claude banner.
struct SessionPromptField: View {
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(AppModel.sessionStartPrompt)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(2)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(AppModel.sessionStartPrompt, forType: .string)
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy the prompt")
            .accessibilityLabel(copied ? "Prompt copied" : "Copy prompt")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }
}
