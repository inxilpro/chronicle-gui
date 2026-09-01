import AppKit
import ChronicleKit
import GRDB
import Observation
import UniformTypeIdentifiers

/// A one-shot instruction for the handoff text view (find bar, scroll/flash).
struct HandoffViewCommand: Equatable {
    enum Kind: Equatable {
        case find, findNext, findPrevious
        case scrollTo(NSRange)
        case scrollToAnchor(String)
    }

    let id = UUID()
    var kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

@MainActor
@Observable
final class AppModel {
    let store: ChronicleStore?
    let launchError: String?
    private let tuple: any TupleCalling

    private(set) var snapshot = AppSnapshot(mode: .waitingCall)
    private(set) var handoff = HandoffDocument(markdown: "")
    private(set) var rendering = HandoffRendering.empty

    /// Decisions with an in-flight review, shown optimistically.
    private(set) var pendingReviews: [String: DecisionStatus] = [:]
    /// Messages whose document reference no longer resolves.
    private(set) var staleReferenceIDs: Set<String> = []

    var collectorWarning: String?
    var actionError: String?
    var feedSelection: String?
    /// Consumed by the feed to scroll to and select a message.
    var feedScrollTarget: String?
    var handoffCommand: HandoffViewCommand?
    var openMainWindow: (() -> Void)?
    /// Drives the Delete Session… confirmation in the main window.
    var confirmDeleteSession = false

    private(set) var textScale: Double

    let notifications = NotificationController()

    private var dismissedWarning: String?
    private var reportedStaleIDs: Set<String> = []
    private var didInitialRefresh = false
    private var requestedNotificationPermission = false
    private var collectorTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var notesWatcher: NotesWatcher?
    private var notesRefreshDebounce: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.editor: EditorApp.phpstorm.rawValue,
            SettingsKey.notifyDecisions: true,
            SettingsKey.notifyMessages: true,
            SettingsKey.handoffTextScale: 1.0,
            SettingsKey.reviewPaneVisible: true,
            SettingsKey.reviewPaneWidth: 380.0,
        ])
        let storedScale = UserDefaults.standard.double(forKey: SettingsKey.handoffTextScale)
        textScale = storedScale > 0 ? storedScale : 1
        tuple = TupleClient.discover()
        do {
            let store = try ChronicleStore(paths: ChroniclePaths())
            self.store = store
            launchError = nil
        } catch {
            store = nil
            launchError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
        notifications.model = self
        notifications.setUp()
        guard let store else { return }
        // Relaunch after a completed/interrupted session shows the waiting
        // screen; stale actives demote before anything renders.
        try? store.clearTerminalSelectionForLaunch()
        _ = try? store.interruptStaleSessions(olderThan: 12 * 3600)
        refresh()
        startObservation()
        startCollector()
    }

    // MARK: - Derived state

    var unreadCount: Int {
        snapshot.messages.count { $0.kind != .ack && !$0.read }
    }

    var selectedMessage: ChatMessage? {
        feedSelection.flatMap { id in snapshot.messages.first { $0.id == id } }
    }

    /// The focused decision row eligible for Approve/Reject commands.
    var selectedUnreviewedDecision: ChatMessage? {
        guard let message = selectedMessage, message.kind == .decision,
            (pendingReviews[message.id] ?? message.decisionStatus) == .unreviewed
        else { return nil }
        return message
    }

    var hasHandoffContent: Bool {
        !snapshot.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sessionIsTerminal: Bool {
        snapshot.sessionState == .complete || snapshot.sessionState == .interrupted
    }

    func source(_ name: String) -> SourceHealth? {
        snapshot.sources.first { $0.source == name }
    }

    var tupleDiscoveryError: String? {
        guard snapshot.mode == .waitingCall else { return nil }
        let tuple = source(SourceName.tuple)
        return tuple?.status == "error" ? tuple?.detail : nil
    }

    func effectiveDecisionStatus(_ message: ChatMessage) -> DecisionStatus? {
        guard message.kind == .decision else { return nil }
        return pendingReviews[message.id] ?? message.decisionStatus
    }

    // MARK: - Refresh pipeline

    func refresh() {
        guard let store else { return }
        do {
            let old = snapshot
            let new = try store.snapshot()
            let markdownChanged = new.markdown != old.markdown || !didInitialRefresh
            if new != old || !didInitialRefresh {
                snapshot = new
            }
            if markdownChanged {
                handoff = HandoffDocument(markdown: new.markdown)
                rendering = HandoffTextBuilder.build(document: handoff, scale: textScale)
            }
            if markdownChanged || new.messages != old.messages {
                updateStaleReferences()
            }
            updateDockBadge()
            notifications.process(snapshot: new, baseline: !didInitialRefresh)
            maybeRequestNotificationPermission(old: old, new: new)
            watchNotes(path: new.notesPath)
            didInitialRefresh = true
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    private func updateDockBadge() {
        NSApplication.shared.dockTile.badgeLabel = FeedFormat.unreadLabel(unreadCount)
    }

    private func updateStaleReferences() {
        guard let store, let sessionId = snapshot.sessionId else {
            staleReferenceIDs = []
            return
        }
        var stale: Set<String> = []
        for message in snapshot.messages where message.kind != .ack {
            guard let reference = message.reference else { continue }
            if handoff.resolve(reference) == nil {
                stale.insert(message.id)
                if !reportedStaleIDs.contains(message.id) {
                    reportedStaleIDs.insert(message.id)
                    try? store.reportStaleReference(
                        sessionId: sessionId, messageId: message.id, locator: reference)
                }
            }
        }
        staleReferenceIDs = stale
    }

    private func maybeRequestNotificationPermission(old: AppSnapshot, new: AppSnapshot) {
        guard !requestedNotificationPermission, new.sessionId != nil,
            old.sessionId == nil || !didInitialRefresh
        else { return }
        requestedNotificationPermission = true
        notifications.requestPermission()
    }

    // MARK: - Database observation

    private func startObservation() {
        guard let store else { return }
        let reader = store.databaseReader
        observationTask = Task { [weak self] in
            let observation = ValueObservation
                .tracking { db in try DBStamp.fetch(db) }
                .removeDuplicates()
            do {
                for try await _ in observation.values(in: reader) {
                    guard let self else { break }
                    self.refresh()
                }
            } catch {
                // The observation only fails if the database goes away.
            }
        }
    }

    // MARK: - Notes file watching

    private func watchNotes(path: String?) {
        if notesWatcher?.path != path {
            notesWatcher = path.map { watched in
                NotesWatcher(path: watched) { [weak self] in
                    self?.scheduleNotesRefresh()
                }
            }
        }
        notesWatcher?.rearmFileWatchIfNeeded()
    }

    private func scheduleNotesRefresh() {
        notesRefreshDebounce?.cancel()
        notesRefreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: - Collector loop

    private func startCollector() {
        guard let store else { return }
        let tuple = self.tuple
        collectorTask = Task { [weak self] in
            var lastSweep = ContinuousClock.now
            while !Task.isCancelled {
                let start = ContinuousClock.now
                let sweep = start - lastSweep > .seconds(1800)
                if sweep { lastSweep = start }
                let warning = await Self.collectPass(store: store, tuple: tuple, sweep: sweep)
                if Task.isCancelled { break }
                self?.handleCollectorResult(warning)
                let elapsed = ContinuousClock.now - start
                if elapsed < .seconds(2) {
                    try? await Task.sleep(for: .seconds(2) - elapsed)
                }
            }
        }
    }

    private nonisolated static func collectPass(
        store: ChronicleStore, tuple: any TupleCalling, sweep: Bool
    ) async -> String? {
        await Task.detached(priority: .utility) {
            if sweep {
                _ = try? store.interruptStaleSessions(olderThan: 12 * 3600)
            }
            do {
                // Health failures are persisted by the collector before it
                // throws; the message only feeds the dismissible banner.
                try Collector.collectOnce(store: store, tuple: tuple, timeout: "2s")
                return nil
            } catch {
                return (error as? ChronicleError)?.message ?? error.localizedDescription
            }
        }.value
    }

    private func handleCollectorResult(_ warning: String?) {
        if let warning {
            if warning != dismissedWarning {
                collectorWarning = warning
            }
        } else {
            collectorWarning = nil
            dismissedWarning = nil
        }
    }

    func dismissCollectorWarning() {
        dismissedWarning = collectorWarning
        collectorWarning = nil
    }

    // MARK: - Review actions

    func review(sessionId: String? = nil, decisionId: String, as status: DecisionStatus) {
        guard let store, let sessionId = sessionId ?? snapshot.sessionId else { return }
        guard status != .unreviewed else { return }
        pendingReviews[decisionId] = status
        Task {
            let failure = await Task.detached {
                do {
                    try store.reviewDecision(sessionId: sessionId, id: decisionId, status: status)
                    try store.markReadThrough(sessionId: sessionId, messageId: decisionId)
                    return nil as String?
                } catch {
                    return (error as? ChronicleError)?.message ?? error.localizedDescription
                }
            }.value
            pendingReviews.removeValue(forKey: decisionId)
            if let failure {
                actionError = failure
            }
            notifications.removeDelivered(decisionId: decisionId)
            refresh()
        }
    }

    func markRead(_ messageId: String) {
        guard let store, let sessionId = snapshot.sessionId else { return }
        // Errors here mean "already read", which is the desired end state.
        try? store.markRead(sessionId: sessionId, messageId: messageId)
        refresh()
    }

    func markAllRead() {
        guard let store, let sessionId = snapshot.sessionId else { return }
        do {
            try store.markReadThrough(sessionId: sessionId, messageId: nil)
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
        notifications.clearCoalesced()
        refresh()
    }

    // MARK: - References

    func openReference(_ message: ChatMessage) {
        guard let reference = message.reference else { return }
        if let resolved = handoff.resolve(reference),
            let range = rendering.renderedRange(
                forSourceRange: resolved.snippetRange, snippet: reference.snippet)
        {
            handoffCommand = HandoffViewCommand(.scrollTo(range))
        } else {
            updateStaleReferences()
        }
    }

    func openFileReference(_ link: FileLink) {
        guard
            let absolute = EditorLink.absolutePath(
                repoRoot: snapshot.repoPath, referencePath: link.path)
        else {
            actionError = "No repository is attached to this session, so \(link.path) cannot be resolved."
            return
        }
        let defaults = UserDefaults.standard
        let editor = EditorApp(rawValue: defaults.string(forKey: SettingsKey.editor) ?? "") ?? .phpstorm
        let template = defaults.string(forKey: SettingsKey.editorTemplate) ?? ""
        guard
            let url = EditorLink.url(
                editor: editor, absolutePath: absolute, line: link.line, template: template)
        else {
            actionError = editor == .custom
                ? "The custom editor URL template is not a valid URL. Check Settings › General."
                : "Cannot build an editor URL for \(link.pathWithLine)."
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Handoff actions

    func copyHandoff() {
        let markdown = snapshot.markdown
        guard hasHandoffContent else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .rtf], owner: nil)
        pasteboard.setString(markdown, forType: .string)
        let rich = HandoffTextBuilder.build(document: handoff, scale: 1).text
        if let rtf = try? rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    func saveHandoffAs() {
        guard let store, let sessionId = snapshot.sessionId else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.chronicleMarkdown]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "planning-handoff.md"
        panel.title = "Save Handoff"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportNotes(sessionId: sessionId, destination: url.path)
            refresh()
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    func setTextScale(_ scale: Double) {
        let clamped = min(max(scale, 0.5), 3)
        guard clamped != textScale else { return }
        textScale = clamped
        UserDefaults.standard.set(clamped, forKey: SettingsKey.handoffTextScale)
        rendering = HandoffTextBuilder.build(document: handoff, scale: clamped)
    }

    func zoomIn() { setTextScale(textScale * 1.1) }
    func zoomOut() { setTextScale(textScale / 1.1) }
    func zoomActualSize() { setTextScale(1) }

    // MARK: - Sessions

    func openHistorySession(_ id: String) {
        guard let store else { return }
        do {
            try store.selectSession(id)
            refresh()
            openMainWindow?()
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    func deleteSession(_ id: String) {
        guard let store else { return }
        do {
            try store.deleteSession(id)
            refresh()
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    func markdownForSession(_ id: String) -> String? {
        guard let store, let record = try? store.session(id) else { return nil }
        return try? String(contentsOfFile: record.notesPath, encoding: .utf8)
    }

    func selectIDECandidate(_ candidateId: String) {
        guard let store, let sessionId = snapshot.sessionId else { return }
        do {
            try store.selectIDECandidate(sessionId: sessionId, candidateId: candidateId)
            refresh()
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - Integration and settings

    var embeddedCLIURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/chronicle")
    }

    func installIntegration() {
        guard let store else { return }
        let executable = embeddedCLIURL
        guard FileManager.default.fileExists(atPath: executable.path) else {
            actionError = "The embedded chronicle CLI is missing from the app bundle."
            return
        }
        do {
            try SkillInstaller.install(
                executable: executable, shim: store.paths.shimURL, skill: store.paths.skillURL)
            refresh()
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    /// True when the installed skill file no longer matches the bundled template.
    var integrationNeedsUpdate: Bool {
        guard let store, snapshot.integrationInstalled else { return false }
        guard let template = try? SkillInstaller.template(),
            let installed = try? String(contentsOf: store.paths.skillURL, encoding: .utf8)
        else { return false }
        let expected = template.replacingOccurrences(
            of: "{{CHRONICLE_BIN}}", with: store.paths.shimURL.path)
        return installed != expected
    }

    func chooseIDEFolder() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: snapshot.ideRoot)
        panel.prompt = "Choose"
        panel.message = "Choose the folder where the Chronicle IDE plugin publishes its data."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try IDEIngestion.validateIDERoot(url)
            try store.setIDERoot(url.path)
            refresh()
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    func resetIDEFolder() {
        guard let store else { return }
        do {
            try store.setSetting("ide_root", to: nil)
            refresh()
        } catch {
            actionError = (error as? ChronicleError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - Find routing

    func findInHandoff() { handoffCommand = HandoffViewCommand(.find) }
    func findNextInHandoff() { handoffCommand = HandoffViewCommand(.findNext) }
    func findPreviousInHandoff() { handoffCommand = HandoffViewCommand(.findPrevious) }
}

// MARK: - Database change fingerprint

/// One cheap read covering every table the UI renders; ValueObservation infers
/// the tracked region from it and `removeDuplicates` suppresses no-op wakeups.
private nonisolated struct DBStamp: Equatable {
    var sessions: String
    var messages: String
    var sourceState: String
    var settings: String
    var candidates: String

    static func fetch(_ db: Database) throws -> DBStamp {
        DBStamp(
            sessions: try String.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) || '|' || COALESCE(MAX(updated_at), '')
                    FROM sessions
                    """) ?? "",
            messages: try String.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) || '|' || COALESCE(SUM(read), 0)
                        || '|' || COUNT(reference_json)
                        || '|' || COALESCE(SUM(CASE decision_status
                                WHEN 'unreviewed' THEN 1
                                WHEN 'approved' THEN 2
                                WHEN 'rejected' THEN 3 ELSE 0 END), 0)
                    FROM chat_messages
                    """) ?? "",
            sourceState: try String.fetchOne(
                db,
                sql: "SELECT COUNT(*) || '|' || COALESCE(MAX(updated_at), '') FROM source_state")
                ?? "",
            settings: try String.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(GROUP_CONCAT(key || '=' || value), '')
                    FROM (SELECT key, value FROM settings ORDER BY key)
                    """) ?? "",
            candidates: try String.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) || '|' || COALESCE(SUM(selected), 0)
                        || '|' || COALESCE(SUM(LENGTH(candidate_json)), 0)
                    FROM ide_candidates
                    """) ?? "")
    }
}

// MARK: - Notes watcher

/// Watches the session's notes.md (and its directory, to survive atomic
/// replaces) with dispatch sources; markdown lives on disk, not in SQLite.
@MainActor
private final class NotesWatcher {
    let path: String
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedFileID: UInt64?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        directorySource = Self.makeSource(
            path: (path as NSString).deletingLastPathComponent,
            mask: [.write, .rename, .delete]
        ) { [weak self] in
            self?.handleEvent()
        }
        rearmFileWatchIfNeeded()
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    func rearmFileWatchIfNeeded() {
        var info = stat()
        let currentID: UInt64? = stat(path, &info) == 0 ? UInt64(info.st_ino) : nil
        guard currentID != watchedFileID || (fileSource == nil && currentID != nil) else { return }
        fileSource?.cancel()
        fileSource = nil
        watchedFileID = currentID
        guard currentID != nil else { return }
        fileSource = Self.makeSource(path: path, mask: [.write, .extend, .delete, .rename]) {
            [weak self] in
            self?.handleEvent()
        }
    }

    private func handleEvent() {
        rearmFileWatchIfNeeded()
        onChange()
    }

    private static func makeSource(
        path: String, mask: DispatchSource.FileSystemEvent, handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated(handler)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.activate()
        return source
    }
}
