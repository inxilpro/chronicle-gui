import AppKit
import ChronicleKit
import SwiftUI
import Sparkle

/// The full menu plan. Items validate (disable) rather than disappear.
struct AppCommands: Commands {
    var model: AppModel
    var updater: SPUUpdater
    @AppStorage(SettingsKey.reviewPaneVisible) private var reviewPaneVisible = true

    var body: some Commands {
        // Chronicle
        CommandGroup(replacing: .appInfo) {
            Button("About Chronicle") { showAbout() }
            Button("Check for Updates…") { updater.checkForUpdates() }
        }

        // File
        CommandGroup(replacing: .newItem) {
            Button("Save Handoff As…") { model.saveHandoffAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.sessionIsTerminal || !model.hasHandoffContent)
            Button("Copy Handoff") { model.copyHandoff() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!model.hasHandoffContent)
        }

        // Edit › Find (routes to the handoff find bar)
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { model.findInHandoff() }
                    .keyboardShortcut("f")
                Button("Find Next") { model.findNextInHandoff() }
                    .keyboardShortcut("g")
                Button("Find Previous") { model.findPreviousInHandoff() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(!model.hasHandoffContent)
        }

        // Session
        CommandMenu("Session") {
            Button("Mark All as Read") { model.markAllRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.unreadCount == 0)
            Button("Approve Decision") {
                if let decision = model.selectedUnreviewedDecision {
                    model.review(decisionId: decision.id, as: .approved)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.selectedUnreviewedDecision == nil)
            Button("Reject Decision") {
                if let decision = model.selectedUnreviewedDecision {
                    model.review(decisionId: decision.id, as: .rejected)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedUnreviewedDecision == nil)
            Divider()
            Button(
                model.snapshot.integrationInstalled
                    ? "Reinstall Claude Integration…" : "Install Claude Integration…"
            ) {
                model.installIntegration()
            }
            Divider()
            Button(model.snapshot.sessionState == .finalizing ? "Finish Session…" : "End Session…") {
                model.confirmEndSession = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!model.sessionCanEnd)
            Button("Close Session") { model.closeSession() }
                .disabled(!model.sessionIsTerminal)
            Button("Delete Session…") { model.confirmDeleteSession = true }
                .disabled(!model.sessionIsTerminal)
        }

        // View
        CommandGroup(before: .toolbar) {
            Button(reviewPaneVisible ? "Hide Review Pane" : "Show Review Pane") {
                reviewPaneVisible.toggle()
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            Divider()
            Button("Actual Size") { model.zoomActualSize() }
                .keyboardShortcut("0")
                .disabled(model.textScale == 1)
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-")
            Divider()
        }

        // Help
        CommandGroup(replacing: .help) {
            Button("Chronicle Help") {
                open("https://github.com/inxilpro/chronicle-gui#readme")
            }
            Button("IDE Wire Contract") {
                open("https://github.com/inxilpro/chronicle-gui/blob/main/docs/ide-wire-contract.md")
            }
        }
    }

    private func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showAbout() {
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string:
                    "The Tuple call companion for live technical planning.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
        ])
    }
}
