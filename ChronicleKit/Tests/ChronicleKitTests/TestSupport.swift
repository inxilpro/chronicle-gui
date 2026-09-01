import Foundation
@testable import ChronicleKit

/// An isolated app home in the system temp directory; nothing touches the real
/// home directory. Removed on deinit.
final class TestHome {
    let root: URL
    let paths: ChroniclePaths
    let store: ChronicleStore

    init(environment: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var paths = ChroniclePaths(appHome: root.appendingPathComponent("app-home", isDirectory: true))
        paths.shimURL = root.appendingPathComponent("bin/chronicle")
        paths.skillURL = root.appendingPathComponent("skills/chronicle/SKILL.md")
        self.paths = paths
        store = try ChronicleStore(paths: paths, environment: environment)
    }

    /// A second store on the same database, as another process would open it.
    func reopenStore() throws -> ChronicleStore {
        try ChronicleStore(paths: paths, environment: [:])
    }

    func scratch(_ component: String) -> URL {
        root.appendingPathComponent(component)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

enum Fixtures {
    static var directory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("chronicle", isDirectory: true)
    }

    static var registry: Data {
        FileManager.default.contents(atPath: directory.appendingPathComponent("sessions.json").path)!
    }

    static var log: Data {
        FileManager.default.contents(atPath: directory.appendingPathComponent("session.jsonl").path)!
    }

    static var logLines: [Data] {
        [UInt8](log).split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    static func candidate() throws -> IDESessionCandidate {
        try IDEIngestion.parseRegistry(registry)[0]
    }

    /// Rewrites one fixture log line through JSONSerialization, mirroring
    /// scribe's mutate_log_line test helper.
    static func mutateLogLine(_ index: Int, _ update: (inout [String: Any]) -> Void) -> Data {
        var lines = logLines
        var value =
            try! JSONSerialization.jsonObject(with: lines[index]) as! [String: Any]
        update(&value)
        lines[index] = try! JSONSerialization.data(withJSONObject: value)
        var result = Data(lines.joined(separator: Data("\n".utf8)))
        result.append(UInt8(ascii: "\n"))
        return result
    }
}

func makeEvent(_ id: String, occurredAt: String, kind: String = "speech") -> NormalizedEvent {
    NormalizedEvent(
        stableId: id, source: "tuple",
        occurredAt: occurredAt, observedAt: "2026-09-01T12:10:00.000Z",
        kind: kind, payload: .object(["text": .string(id)]))
}

@discardableResult
func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = directory
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A committed git repository in the test sandbox for attach/file-reference tests.
func makeGitRepository(at url: URL) throws -> String {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try runGit(["init", "--quiet"], in: url)
    try runGit(["config", "user.email", "test@example.com"], in: url)
    try runGit(["config", "user.name", "Chronicle Tests"], in: url)
    try runGit(["commit", "--allow-empty", "--quiet", "-m", "initial"], in: url)
    return GitClient.canonicalize(url.path)
}

/// A shell-script Tuple CLI mock, like scribe's tests use.
func makeTupleMock(in directory: URL, body: String) throws -> TupleClient {
    let executable = directory.appendingPathComponent("tuple-mock-\(UUID().uuidString)")
    try "#!/bin/sh\nset -eu\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return TupleClient(executable: executable)
}

struct FakeTuple: TupleCalling {
    var callId: String?
    var failure: String?

    func currentCall() throws -> String? {
        if let failure {
            throw ChronicleError(failure)
        }
        return callId
    }

    func collect(store: ChronicleStore, session: SessionRecord, timeout: String) throws {}
}
