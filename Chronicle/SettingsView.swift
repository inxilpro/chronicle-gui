import SwiftUI
import Sparkle
import ChronicleKit

struct SettingsView: View {
    @Bindable var model: AppModel
    var updater: SPUUpdater

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationSettings(model: model)
                .tabItem { Label("Integration", systemImage: "puzzlepiece.extension") }
            UpdateSettings(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @AppStorage(SettingsKey.editor) private var editor = EditorApp.phpstorm.rawValue
    @AppStorage(SettingsKey.editorTemplate) private var editorTemplate = ""
    @AppStorage(SettingsKey.notifyDecisions) private var notifyDecisions = true
    @AppStorage(SettingsKey.notifyMessages) private var notifyMessages = true

    var body: some View {
        Form {
            Section {
                Picker("Open files in:", selection: $editor) {
                    ForEach(EditorApp.allCases) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
                if editor == EditorApp.custom.rawValue {
                    TextField(
                        "URL template:", text: $editorTemplate,
                        prompt: Text("myeditor://open?file={path}&line={line}"))
                    Text("Use {path} and {line} placeholders; {path} is the absolute file path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Editor")
            }
            Section {
                LabeledContent("Chronicle folder:") {
                    Text(model.snapshot.ideRoot)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(model.snapshot.ideRoot)
                }
                HStack {
                    Button("Choose…") { model.chooseIDEFolder() }
                    Button("Reset") { model.resetIDEFolder() }
                }
                Text("Where the Chronicle IDE plugin publishes its session data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("IDE Plugin")
            }
            Section {
                Toggle("Notify about new decisions", isOn: $notifyDecisions)
                Toggle("Notify about new review notes", isOn: $notifyMessages)
                Text("Decision notifications include Approve and Reject buttons. Review notes are coalesced into a single notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

// MARK: - Integration

private struct IntegrationSettings: View {
    @Bindable var model: AppModel

    private var shimPath: String {
        model.store?.paths.shimURL.path ?? ""
    }

    private var skillPath: String {
        model.store?.paths.skillURL.path ?? ""
    }

    private var statusText: String {
        if !model.snapshot.integrationInstalled {
            "Not installed"
        } else if model.integrationNeedsUpdate {
            "Installed — update available"
        } else {
            "Installed"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status:", value: statusText)
                LabeledContent("CLI shim:") {
                    Text(shimPath)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(shimPath)
                }
                LabeledContent("Claude skill:") {
                    Text(skillPath)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(skillPath)
                }
                Button(model.snapshot.integrationInstalled ? "Reinstall Integration" : "Install Integration") {
                    model.installIntegration()
                }
            } header: {
                Text("Claude Integration")
            } footer: {
                Text("Installing links the embedded chronicle CLI into ~/.chronicle/bin and writes the chronicle skill for Claude Code. The skill lets Claude follow your Tuple call and maintain the planning handoff.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("To use the chronicle CLI from your own shell, link it into /usr/local/bin:")
                    .font(.callout)
                Text("ln -s \(shimPath) /usr/local/bin/chronicle")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            } header: {
                Text("Command Line (Optional)")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    var updater: SPUUpdater
    @State private var automaticChecks: Bool
    @State private var canCheck = true

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) {
                        updater.automaticallyChecksForUpdates = automaticChecks
                    }
                LabeledContent(
                    "Version:",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "—")
                Button("Check for Updates Now") {
                    updater.checkForUpdates()
                }
                .disabled(!canCheck)
            } header: {
                Text("Software Updates")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { value in
            canCheck = value
        }
    }
}
