import SwiftUI
import ChronicleKit

/// Three status dots (tuple / claude / chronicle), each with a text label —
/// never color alone — a tooltip, and a shared popover with full detail.
struct SourceStrip: View {
    var sources: [SourceHealth]
    @State private var detailShown = false

    var body: some View {
        HStack(spacing: 12) {
            ForEach(sources, id: \.source) { source in
                Button {
                    detailShown.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(source.statusValue?.tint ?? Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(source.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("\(source.label)\(source.detail.map { " — \($0)" } ?? "")")
                .accessibilityLabel("\(source.displayName), \(source.label)")
            }
        }
        .popover(isPresented: $detailShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sources, id: \.source) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(source.statusValue?.tint ?? Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(source.displayName)
                                .fontWeight(.semibold)
                            Text(source.label)
                                .foregroundStyle(.secondary)
                        }
                        if let detail = source.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .frame(minWidth: 240, maxWidth: 340, alignment: .leading)
        }
    }
}
