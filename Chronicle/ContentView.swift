import SwiftUI
import ChronicleKit

/// Main window content: waiting screen or the review/handoff split.
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.reviewPaneWidth) private var reviewPaneWidth = 380.0
    @AppStorage(SettingsKey.reviewPaneVisible) private var reviewPaneVisible = true

    var body: some View {
        Group {
            if let launchError = model.launchError {
                launchFailure(launchError)
            } else if model.snapshot.mode == .waitingCall {
                WaitingView(model: model)
            } else {
                split
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
        }
        .alert(
            "Chronicle",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            model.endSessionPrompt,
            isPresented: $model.confirmEndSession,
            titleVisibility: .visible
        ) {
            Button(model.snapshot.sessionState == .finalizing ? "Finish Session" : "End Session") {
                model.endSession()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this Chronicle session and its internal handoff? Saved copies are not affected.",
            isPresented: $model.confirmDeleteSession,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let sessionId = model.snapshot.sessionId {
                    model.deleteSession(sessionId)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var split: some View {
        HStack(spacing: 0) {
            if reviewPaneVisible {
                ReviewPane(model: model)
                    .frame(width: reviewPaneWidth)
                SplitDivider(width: $reviewPaneWidth, range: 320...560)
            }
            HandoffPane(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func launchFailure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Chronicle could not open its data store")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keyboard-accessible drag splitter for the review/handoff panes.
struct SplitDivider: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    @State private var dragBase: Double?
    @FocusState private var focused: Bool

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 9)
            .overlay(Divider())
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragBase ?? width
                        dragBase = base
                        width = (base + value.translation.width).clamped(to: range)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .focusable()
            .focused($focused)
            .focusEffectDisabled(false)
            .onMoveCommand { direction in
                switch direction {
                case .left: width = (width - 16).clamped(to: range)
                case .right: width = (width + 16).clamped(to: range)
                default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Review pane splitter")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = (width + 16).clamped(to: range)
                case .decrement: width = (width - 16).clamped(to: range)
                @unknown default: break
                }
            }
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
