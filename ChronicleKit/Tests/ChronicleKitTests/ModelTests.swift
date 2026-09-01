import Foundation
import Testing
@testable import ChronicleKit

@Suite struct TimestampTests {
    @Test func wireFormatRoundTrips() throws {
        let string = "2026-09-01T12:00:00.000Z"
        let date = try #require(ChronicleTimestamp.date(from: string))
        #expect(ChronicleTimestamp.string(from: date) == string)
        #expect(ChronicleTimestamp.isWireFormat(string))
        #expect(!ChronicleTimestamp.isWireFormat("2026-09-01T12:00:00Z"))
        #expect(!ChronicleTimestamp.isWireFormat("2026-09-01T12:00:00.0000Z"))
    }
}

@Suite struct PathTests {
    @Test func safeSessionIdPassesThroughSimpleIds() {
        #expect(ChroniclePaths.safeSessionId("call-123_ABC") == "call-123_ABC")
    }

    @Test func safeSessionIdHashesUnsafeIds() {
        let safe = ChroniclePaths.safeSessionId("weird id/with:stuff")
        #expect(safe.hasPrefix("call-"))
        #expect(safe.count == 5 + 16)
    }
}
