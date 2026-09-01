import Foundation
import CryptoKit

/// Every stored or emitted timestamp is UTC RFC 3339 with exactly three fractional digits,
/// e.g. `2026-09-01T12:00:00.000Z`.
public enum ChronicleTimestamp {
    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func now() -> String {
        string(from: Date())
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }

    /// True only for the exact wire shape `YYYY-MM-DDTHH:MM:SS.mmmZ` (24 bytes).
    public static func isWireFormat(_ string: String) -> Bool {
        guard string.utf8.count == 24 else { return false }
        return date(from: string) != nil && string.hasSuffix("Z") && string[string.index(string.startIndex, offsetBy: 10)] == "T"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

}

public enum SHA256Hex {
    public static func hash(_ string: String) -> String {
        hash(Data(string.utf8))
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
