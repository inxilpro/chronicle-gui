import SwiftUI
import ChronicleKit

/// Quiet single-line row for `ack` messages; always read, never selectable.
struct AckRow: View {
    var message: ChatMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            Text(inlineMarkdown(message.text))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(TimestampFormat.time(message.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Note: \(message.text)")
    }
}

/// Bubble row for plain `message` messages.
struct MessageRow: View {
    var message: ChatMessage
    var isSelected: Bool
    var isStale: Bool
    var onOpenReference: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(inlineMarkdown(message.text))
                Spacer(minLength: 8)
                if !message.read {
                    NewPill()
                }
                Text(TimestampFormat.time(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let reference = message.reference, !isStale {
                ReferenceChip(reference: reference, action: onOpenReference)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            message.read ? "Message: \(message.text)" : "Unread message: \(message.text)")
    }
}

/// Card row for `decision` messages. Unreviewed cards carry the Approve/Reject
/// surface; reviewed cards keep their box but drop the buttons and status line,
/// fading behind a state icon and title instead. The linked handoff section is
/// reachable through the context menu's Jump to Section, not an inline link.
struct DecisionRow: View {
    var message: ChatMessage
    var status: DecisionStatus
    var isSelected: Bool
    var onApprove: () -> Void
    var onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                statusIcon
                    .accessibilityHidden(true)
                Text(FeedFormat.decisionTitle(status))
                    .font(.headline)
                Spacer(minLength: 8)
                if !message.read && status == .unreviewed {
                    NewPill()
                }
                Text(TimestampFormat.time(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
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
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
        )
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Unreviewed keeps the accent diamond that asks for action; approved fades
    /// to a gray check (green still reads as a call to action); rejected gets a
    /// red X because a rejection is worth spotting when scrolling back.
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .unreviewed:
            Text("◆")
                .foregroundStyle(Color.accentColor)
        case .approved:
            Image(systemName: "checkmark.square")
                .foregroundStyle(.secondary)
        case .rejected:
            Image(systemName: "xmark.square.fill")
                .foregroundStyle(.red)
        }
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        return status == .unreviewed ? Color.accentColor.opacity(0.5) : .clear
    }

    private var accessibilitySummary: String {
        switch status {
        case .unreviewed where !message.read: "Decision requested, unreviewed: \(message.text)"
        case .unreviewed: "Decision requested: \(message.text)"
        case .approved: "Decision approved: \(message.text)"
        case .rejected: "Decision rejected: \(message.text)"
        }
    }
}

struct NewPill: View {
    var body: some View {
        Text("New")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("Unread")
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
struct TypingIndicatorRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack {
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
