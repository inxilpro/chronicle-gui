import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ChronicleKit

nonisolated enum BuildFlags {
    /// Sparkle only runs in Release builds; an Xcode dev build never checks
    /// the appcast (unsigned builds would fail EdDSA validation anyway).
    static let sparkleEnabled: Bool = {
        #if DEBUG
            false
        #else
            true
        #endif
    }()
}

nonisolated enum SettingsKey {
    static let editor = "editor"
    static let editorTemplate = "editorCustomTemplate"
    static let notifyDecisions = "notifyDecisions"
    static let notifyMessages = "notifyMessages"
    static let reviewPaneWidth = "reviewPaneWidth"
    static let reviewPaneVisible = "reviewPaneVisible"
    static let handoffTextScale = "handoffTextScale"
    static let historySortKey = "historySortKey"
    static let historySortAscending = "historySortAscending"
}

nonisolated enum TimestampFormat {
    static func time(_ wire: String) -> String {
        guard let date = ChronicleTimestamp.date(from: wire) else { return wire }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func dateTime(_ wire: String) -> String {
        guard let date = ChronicleTimestamp.date(from: wire) else { return wire }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

nonisolated func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)))
        ?? AttributedString(text)
}

nonisolated extension UTType {
    static var chronicleMarkdown: UTType {
        UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    }
}

/// Drag-out payload: a promised `planning-handoff.md` file containing the
/// handoff — markdown captured up front, or a notes path read only when the
/// drop actually lands (History rows would otherwise read every session's
/// notes file on each render).
nonisolated struct HandoffFileTransfer: Transferable {
    var markdown: String? = nil
    var notesPath: String? = nil

    private var resolvedMarkdown: String {
        if let markdown { return markdown }
        return notesPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .chronicleMarkdown) { transfer in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("chronicle-drag-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("planning-handoff.md")
            try Data(transfer.resolvedMarkdown.utf8).write(to: file)
            return SentTransferredFile(file)
        }
        DataRepresentation(exportedContentType: .plainText) { transfer in
            Data(transfer.resolvedMarkdown.utf8)
        }
    }
}

nonisolated extension SourceHealth {
    var statusValue: SourceStatus? { SourceStatus(rawValue: status) }

    /// The `claude` source is whichever agent runs the skill and the
    /// `chronicle` source is the IDE plugin; the wire names are part of the
    /// skill contract, so only the labels say "Agent" and "IDE".
    var displayName: String {
        switch source {
        case SourceName.tuple: "Tuple"
        case SourceName.claude: "Agent"
        case SourceName.chronicle: "IDE"
        default: source.capitalized
        }
    }
}

extension SourceStatus {
    var tint: Color {
        switch self {
        case .live, .connected: .green
        case .waiting, .ended: .secondary
        case .stopped, .ambiguous: .orange
        case .error: .red
        case .off: Color(nsColor: .quaternaryLabelColor)
        }
    }
}

extension SessionState {
    var displayName: String {
        switch self {
        case .active: "Active"
        case .finalizing: "Finalizing"
        case .complete: "Complete"
        case .interrupted: "Interrupted"
        }
    }
}
