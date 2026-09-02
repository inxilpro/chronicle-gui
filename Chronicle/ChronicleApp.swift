import SwiftUI
import Sparkle

@main
struct ChronicleApp: App {
    @State private var model = AppModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: BuildFlags.sparkleEnabled, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Chronicle", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppCommands(model: model, updater: updaterController.updater)
        }

        Window("History", id: "history") {
            HistoryView(model: model)
        }
        // ⌘Y matches Safari's History; ⌥⌘H would shadow the system's Hide Others.
        .keyboardShortcut("y")
        .defaultSize(width: 600, height: 420)

        Settings {
            SettingsView(model: model, updater: updaterController.updater)
        }
    }
}
