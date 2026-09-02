import SwiftUI
import ChronicleKit

/// Shared skeleton for every feed row: a fixed-width status-icon gutter, the
/// content column, and a trailing timestamp gutter. Icon and timestamp hang
/// from the first text baseline so every row kind lines up identically.
struct FeedRow<Icon: View, Content: View>: View {
    var time: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon()
                .frame(width: 16)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

extension View {
    /// The shared bubble chrome. Selection draws the accent outline here
    /// because the list's platform highlight is suppressed.
    fileprivate func feedBubble(isSelected: Bool) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
    }
}

/// Quiet row for `ack` messages; always read, never selectable. Keeps the
/// shared gutters but drops the bubble, so its text aligns with the bubble
/// edges above and below it.
struct AckRow: View {
    var message: ChatMessage

    var body: some View {
        FeedRow(time: TimestampFormat.time(message.timestamp)) {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
        } content: {
            Text(inlineMarkdown(message.text))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Note: \(message.text)")
    }
}

/// Bubble row for plain `message` messages. Read state lives entirely in the
/// gutter dot — accent while unread, fading to gray once read.
struct MessageRow: View {
    var message: ChatMessage
    var isSelected: Bool
    var isStale: Bool
    var onOpenReference: () -> Void

    var body: some View {
        FeedRow(time: TimestampFormat.time(message.timestamp)) {
            Image(systemName: "circle.fill")
                .foregroundStyle(
                    message.read ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text(inlineMarkdown(message.text))
                if let reference = message.reference, !isStale {
                    ReferenceChip(reference: reference, action: onOpenReference)
                }
            }
            .feedBubble(isSelected: isSelected)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            message.read ? "Message: \(message.text)" : "Unread message: \(message.text)")
    }
}

/// Bubble row for `decision` messages. Unreviewed rows carry the Approve/Reject
/// surface behind an accent diamond; reviewed rows drop the buttons and fade —
/// including rejected (gray, not red): a settled rejection is history, not an
/// alert. The linked handoff section is reachable through the context menu's
/// Jump to Section, not an inline link.
struct DecisionRow: View {
    var message: ChatMessage
    var status: DecisionStatus
    var isSelected: Bool
    var onApprove: () -> Void
    var onReject: () -> Void

    var body: some View {
        FeedRow(time: TimestampFormat.time(message.timestamp)) {
            statusIcon
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(FeedFormat.decisionTitle(status))
                    .font(.headline)
                Text(inlineMarkdown(message.text))
                if status == .unreviewed {
                    HStack(spacing: 8) {
                        Button("Approve", action: onApprove)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityLabel("Approve decision")
                        Button("Reject", action: onReject)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Reject decision")
                    }
                }
            }
            .foregroundStyle(
                status == .rejected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .feedBubble(isSelected: isSelected)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .unreviewed:
            Image(systemName: "questionmark.diamond.fill")
                .foregroundStyle(Color.accentColor)
        case .approved:
            Image(systemName: "checkmark.diamond.fill")
                .foregroundStyle(.tertiary)
        case .rejected:
            Image(systemName: "xmark.diamond.fill")
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilitySummary: String {
        let title = FeedFormat.decisionTitle(status)
        if status == .unreviewed, !message.read {
            return "\(title), unread: \(message.text)"
        }
        return "\(title): \(message.text)"
    }
}

/// Shows the last heading segment plus a snippet; clicking scrolls the handoff
/// pane. Unresolvable references are hidden by the rows (the stale report to
/// the skill unlinks them) rather than rendered broken.
struct ReferenceChip: View {
    var reference: DocumentReference
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            chipLabel
        }
        .buttonStyle(.plain)
        .help("Show in the planning handoff")
        .accessibilityLabel("Reference: \(headingText)")
    }

    private var headingText: String {
        reference.heading.last ?? "Handoff"
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.quote")
                .imageScale(.small)
            Text(headingText)
                .fontWeight(.medium)
            Text(reference.snippet)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The iMessage-style three-dot bubble shown at the bottom of the feed while
/// the agent has signaled `chronicle working` and nothing new has landed yet.
/// Keeps the shared icon gutter so it lines up with the real rows.
struct TypingIndicatorRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 16, height: 1)
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(animating ? 1 : 0.3)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 0.45)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.16),
                            value: animating)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .onAppear { animating = true }
        .accessibilityElement()
        .accessibilityLabel("Claude is working")
    }
}
