import SwiftUI
import ChronicleKit

/// Quiet single-line row for `ack` messages; always read.
struct AckRow: View {
    var message: ChatMessage

    var body: some View {
        HStack(spacing: 6) {
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
    var isStale: Bool
    var onOpenReference: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(inlineMarkdown(message.text))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if !message.read {
                    NewPill()
                }
            }
            HStack(spacing: 8) {
                if let reference = message.reference {
                    ReferenceChip(reference: reference, isStale: isStale, action: onOpenReference)
                }
                Spacer(minLength: 0)
                Text(TimestampFormat.time(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            message.read ? "Message: \(message.text)" : "Unread message: \(message.text)")
    }
}

/// Card row for `decision` messages with the Approve/Reject confirmation surface.
struct DecisionRow: View {
    var message: ChatMessage
    var status: DecisionStatus
    var isPending: Bool
    var pendingStatus: DecisionStatus?
    var isStale: Bool
    var onApprove: () -> Void
    var onReject: () -> Void
    var onOpenReference: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("◆")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Decision requested")
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
                .textSelection(.enabled)
            if let reference = message.reference {
                ReferenceChip(reference: reference, isStale: isStale, action: onOpenReference)
            }
            footer
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    status == .unreviewed ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: 1)
        )
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var footer: some View {
        switch (status, isPending, pendingStatus) {
        case (.unreviewed, true, let pending):
            Text(pending == .rejected ? "Rejecting…" : "Approving…")
                .font(.callout)
                .foregroundStyle(.secondary)
        case (.unreviewed, false, _):
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
        case (.approved, _, _):
            Text("Approved ✓")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        case (.rejected, _, _):
            Text("Rejected ×")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
        }
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
/// pane. Unresolvable references render stale and non-interactive.
struct ReferenceChip: View {
    var reference: DocumentReference
    var isStale: Bool
    var action: () -> Void

    var body: some View {
        if isStale {
            chipLabel
                .foregroundStyle(.tertiary)
                .help("This part of the handoff has changed; the reference no longer resolves.")
                .accessibilityLabel("Stale reference: \(headingText)")
        } else {
            Button(action: action) {
                chipLabel
            }
            .buttonStyle(.plain)
            .help("Show in the planning handoff")
            .accessibilityLabel("Reference: \(headingText)")
        }
    }

    private var headingText: String {
        reference.heading.last ?? "Handoff"
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: isStale ? "text.badge.xmark" : "text.quote")
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
