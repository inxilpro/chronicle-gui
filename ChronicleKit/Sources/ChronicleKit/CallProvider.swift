import Foundation

/// A source of live calls: call detection plus one transcription-collection
/// pass. Tuple is the only provider today; this seam exists so another call
/// source (Zoom, local audio capture) can slot in without touching the
/// collector, the store, or the CLI. Tests substitute fakes or shell-script
/// mocks through the same protocol.
public protocol CallProvider: Sendable {
    /// The stable wire value for this provider's source-health row and lock
    /// files. For Tuple this is `SourceName.tuple`, which the skill contract
    /// documents; a new provider introduces a new value.
    var id: String { get }

    /// The user-facing product name ("Tuple").
    var displayName: String { get }

    /// The current call's ID, or nil when the provider reports no call.
    func currentCall() throws -> String?

    /// One collection pass for the session, importing whatever the provider
    /// returns. The provider owns its own resume state: Tuple keeps a durable
    /// server-side cursor; a provider without one persists its position in
    /// `source_state.cursor_json` (see `IDEIngestion` for the pattern).
    func collect(store: ChronicleStore, session: SessionRecord, timeout: String) throws
}
