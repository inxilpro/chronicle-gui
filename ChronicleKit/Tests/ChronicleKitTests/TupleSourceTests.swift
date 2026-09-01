import Foundation
import Testing
@testable import ChronicleKit

@Suite struct TupleRecordParserTests {
    @Test func speechAlignsToSpokenStartTime() {
        let batch = TupleRecordParser.parse(
            Data(
                """
                {"type":"transcription_finished","time":"2026-09-01T12:00:09Z","data":{"start":"2026-09-01T12:00:01Z","user_id":"u1","text":"Hello"}}
                {"type":"user_audio_started","time":"2026-09-01T12:00:00Z","data":{}}

                """.utf8))
        #expect(batch.events.count == 1)
        #expect(batch.events[0].kind == "speech")
        #expect(batch.events[0].occurredAt == "2026-09-01T12:00:01.000Z")
        #expect(batch.events[0].payload["text"]?.stringValue == "Hello")
        #expect(batch.events[0].payload["speakerId"]?.stringValue == "u1")
        #expect(batch.events[0].payload["raw"]?["type"]?.stringValue == "transcription_finished")
        #expect(batch.events[0].stableId.hasPrefix("tuple:"))
        #expect(batch.status?.status == "live")
    }

    @Test func callEndIsTerminalButRecordingEndIsNot() {
        let recording = TupleRecordParser.parse(
            Data("{\"type\":\"recording_ended\",\"time\":\"2026-09-01T12:00:09Z\",\"data\":{}}\n".utf8))
        #expect(!recording.callEnded)
        #expect(recording.status?.status == "stopped")

        let ended = TupleRecordParser.parse(Data("{\"kind\":\"status\",\"status\":\"call_ended\"}\n".utf8))
        #expect(ended.callEnded)
        #expect(ended.events[0].kind == "call_ended")
        #expect(ended.events[0].stableId == "tuple:call-ended")
        #expect(ended.status?.status == "ended")
    }

    @Test func emptySpeechIsDroppedAndGapsStop() {
        let batch = TupleRecordParser.parse(
            Data(
                """
                {"type":"transcription_finished","time":"2026-09-01T12:00:09Z","data":{"start":"2026-09-01T12:00:01Z","text":"   "}}
                {"type":"transcription_dropped","time":"2026-09-01T12:00:10Z","data":{}}

                """.utf8))
        #expect(batch.events.map(\.kind) == ["transcription_dropped"])
        #expect(batch.status?.status == "stopped")
        #expect(batch.status?.detail.contains("will not restart it automatically") == true)
    }

    @Test func stableIdentityFallsBackThroughIdShapes() {
        let batch = TupleRecordParser.parse(
            Data(
                """
                {"type":"speech_event","id":"abc","time":"2026-09-01T12:00:01Z","data":{}}
                {"type":"speech_event","time":"2026-09-01T12:00:02Z","data":{"id":42}}
                {"type":"speech_event","time":"2026-09-01T12:00:03Z","data":{"id":{"id":"nested"}}}
                {"type":"speech_event","time":"2026-09-01T12:00:04Z","data":{}}

                """.utf8))
        #expect(batch.events[0].stableId == "tuple:speech_event:abc")
        #expect(batch.events[1].stableId == "tuple:speech_event:42")
        #expect(batch.events[2].stableId == "tuple:speech_event:nested")
        #expect(batch.events[3].stableId.hasPrefix("tuple:"))
        #expect(batch.events[3].stableId.count == "tuple:".count + 64)
    }

    @Test func malformedLinesAreCountedNotFatal() {
        let batch = TupleRecordParser.parse(
            Data(
                """
                not-json
                {"type":"transcription_started","time":"2026-09-01T12:00:01Z","data":{}}
                also broken {

                """.utf8))
        #expect(batch.malformed == 2)
        #expect(batch.events.count == 1)
        #expect(batch.status?.status == "live")
    }

    @Test func eventsSortByOccurrenceThenStableId() {
        let batch = TupleRecordParser.parse(
            Data(
                """
                {"type":"transcription_finished","id":"b","time":"2026-09-01T12:00:09Z","data":{"start":"2026-09-01T12:00:05Z","text":"later"}}
                {"type":"transcription_finished","id":"a","time":"2026-09-01T12:00:09Z","data":{"start":"2026-09-01T12:00:01Z","text":"earlier"}}

                """.utf8))
        #expect(batch.events.map(\.occurredAt) == ["2026-09-01T12:00:01.000Z", "2026-09-01T12:00:05.000Z"])
    }
}

@Suite struct TupleClientTests {
    @Test func mockCatchesUpAndRecognizesCallEnd() throws {
        let home = try TestHome()
        let recordedArgs = home.scratch("tuple-args")
        let tuple = try makeTupleMock(
            in: home.root,
            body: """
                if [ "$1" = "call" ]; then
                  printf '%s\\n' '{"id":"call-mock"}'
                  exit 0
                fi
                printf '%s\\n' "$*" > '\(recordedArgs.path)'
                printf '%s\\n' \\
                  '{"type":"transcription_finished","time":"2026-09-01T12:00:09.000Z","data":{"start":"2026-09-01T12:00:01.000Z","user_id":"u1","text":"Hello"}}' \\
                  '{"kind":"status","status":"call_ended"}'
                """)
        try Collector.collectOnce(store: home.store, tuple: tuple, timeout: "1ms")
        let args = try String(contentsOf: recordedArgs, encoding: .utf8)
        for expected in [
            "transcription show call-mock", "--wait", "--with-events",
            "--cursor chronicle-call-mock", "--format json",
        ] {
            #expect(args.contains(expected), "missing Tuple CLI option: \(expected)")
        }
        let session = try #require(try home.store.currentSession())
        #expect(session.id == "call-mock")
        #expect(session.state == .finalizing)
        let result = try home.store.show(sessionId: session.id, consumer: "tuple-mock-test", limit: 10)
        #expect(result.events.map(\.kind).sorted() == ["call_ended", "speech"])
    }

    @Test func transcriptionOffIsWaitingBeforeLiveAndStoppedAfter() throws {
        let home = try TestHome()
        let tuple = try makeTupleMock(
            in: home.root,
            body: """
                if [ "$1" = "call" ]; then
                  printf '%s\\n' '{"id":"call-mock"}'
                  exit 0
                fi
                echo 'transcription is not running' >&2
                exit 1
                """)
        try Collector.collectOnce(store: home.store, tuple: tuple, timeout: "1ms")
        var health = try home.store.sourceHealth(sessionId: "call-mock")[0]
        #expect(health.status == "waiting")
        #expect(health.detail?.contains("start it in Tuple") == true)

        try home.store.setSourceState(
            sessionId: "call-mock", source: "tuple", status: "live", detail: "Transcription is live.")
        let session = try #require(try home.store.currentSession())
        try tuple.collect(store: home.store, session: session, timeout: "1ms")
        health = try home.store.sourceHealth(sessionId: "call-mock")[0]
        #expect(health.status == "stopped")
        #expect(health.detail?.contains("stopped during the call") == true)
    }

    @Test func currentCallAcceptsThePublicJSONContract() throws {
        let home = try TestHome()
        let tuple = try makeTupleMock(
            in: home.root, body: "printf '%s\\n' '{\"call_id\":\"call-current\",\"transcribing\":false}'")
        #expect(try tuple.currentCall() == "call-current")

        let noCall = try makeTupleMock(
            in: home.root, body: "echo 'not in a call' >&2\nexit 1")
        #expect(try noCall.currentCall() == nil)

        let noId = try makeTupleMock(in: home.root, body: "printf '%s\\n' '{\"transcribing\":true}'")
        #expect(throws: ChronicleError("Tuple current-call JSON did not contain an ID")) {
            _ = try noId.currentCall()
        }
    }

    @Test func currentCallExplainsAuthorizationErrorsFromStdout() throws {
        let home = try TestHome()
        let tuple = try makeTupleMock(
            in: home.root, body: "echo 'authorization denied by Tuple CLI Server'\nexit 1")
        let error = try #require(captureError { _ = try tuple.currentCall() })
        #expect(error.message.contains("Settings → Integrations → CLI Server"))
        #expect(error.message.contains("authorization denied by Tuple CLI Server"))
        #expect(error.message.contains("exit status: 1"))
    }

    @Test func currentCallPreservesASilentFailureAndNextStep() throws {
        let home = try TestHome()
        let tuple = try makeTupleMock(in: home.root, body: "exit 7")
        let error = try #require(captureError { _ = try tuple.currentCall() })
        #expect(error.message.contains("returned no diagnostic output"))
        #expect(error.message.contains("tuple call current --format json"))
        #expect(error.message.contains("exit status: 7"))
    }

    @Test func transcriptionAuthorizationIsNotMisreportedAsCaptureOff() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-mock")
        let tuple = try makeTupleMock(
            in: home.root, body: "echo 'not authorized to access transcription' >&2\nexit 1")
        let error = try #require(
            captureError { try tuple.collect(store: home.store, session: session, timeout: "1ms") })
        #expect(error.message.contains("CLI access is not authorized"))
        let health = try home.store.sourceHealth(sessionId: session.id)[0]
        #expect(health.status == "error")
        #expect(health.detail?.contains("not authorized to access transcription") == true)
    }

    @Test func transcriptionReportsTheSpecificMacOSPermission() throws {
        let home = try TestHome()
        let session = try home.store.createOrResumeSession(callId: "call-mock")
        let tuple = try makeTupleMock(
            in: home.root, body: "echo 'microphone permission denied' >&2\nexit 1")
        let error = try #require(
            captureError { try tuple.collect(store: home.store, session: session, timeout: "1ms") })
        #expect(error.message.contains("System Settings → Privacy & Security → Microphone"))
        #expect(error.message.contains("microphone permission denied"))
    }

    @Test func missingTupleCLIIsVisibleWhileWaitingForACall() throws {
        let home = try TestHome()
        let tuple = TupleClient(executable: home.scratch("missing-tuple"))
        #expect(throws: (any Error).self) {
            try Collector.collectOnce(store: home.store, tuple: tuple, timeout: "1ms")
        }
        let snapshot = try home.store.snapshot()
        #expect(snapshot.sources[0].status == "error")
        #expect(snapshot.sources[0].detail?.contains("Install CLI") == true)
    }

    @Test func collectorKeepsCollectingAfterCallDisappears() throws {
        let home = try TestHome()
        _ = try home.store.createOrResumeSession(callId: "call-gone")
        let flag = home.scratch("collected")
        let tuple = try makeTupleMock(
            in: home.root,
            body: """
                if [ "$1" = "call" ]; then
                  echo 'not in a call' >&2
                  exit 1
                fi
                touch '\(flag.path)'
                printf '%s\\n' '{"kind":"status","status":"call_ended"}'
                """)
        try Collector.collectOnce(store: home.store, tuple: tuple, timeout: "1ms")
        #expect(FileManager.default.fileExists(atPath: flag.path))
        #expect(try home.store.session("call-gone").state == .finalizing)
    }
}

func captureError(_ body: () throws -> Void) -> ChronicleError? {
    do {
        try body()
        return nil
    } catch {
        return error as? ChronicleError
    }
}
