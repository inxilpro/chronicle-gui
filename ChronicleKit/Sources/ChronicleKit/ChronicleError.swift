import Foundation

/// A user-facing failure. The CLI prints `chronicle: <message>` and exits 1.
public struct ChronicleError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
