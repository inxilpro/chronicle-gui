import SwiftUI
import ChronicleKit

/// Centered guidance shown when there is no session (`waitingCall`).
struct WaitingView: View {
    @Bindable var model: AppModel

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
            Text("Waiting for a Tuple call")
                .font(.title.weight(.semibold))
                .accessibilityHeading(.h1)
            Text(
                "Join a call in Tuple and Chronicle will detect it automatically. Start transcription in Tuple when you're ready."
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

            if !model.snapshot.integrationInstalled {
                Button("Install Claude Integration") {
                    model.installIntegration()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
            }

            if !model.snapshot.ideRegistryFound {
                HStack(spacing: 4) {
                    Text("Chronicle IDE data was not found at \(model.snapshot.ideRoot).")
                    Button("Choose Chronicle Folder…") {
                        model.chooseIDEFolder()
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
