import Foundation

public enum GitClient {
    /// `git -C <start> rev-parse --show-toplevel`, canonicalized.
    public static func repositoryRoot(startingAt start: String) throws -> String {
        let output = try run(["-C", start, "rev-parse", "--show-toplevel"])
        guard output.succeeded else {
            throw ChronicleError("\(start) is not inside a Git repository")
        }
        guard let root = String(data: output.stdout, encoding: .utf8) else {
            throw ChronicleError("git returned a non-UTF-8 repository path")
        }
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        return canonicalize(trimmed)
    }

    public static func headSHA(repository: String) throws -> String {
        let output = try run(["-C", repository, "rev-parse", "--verify", "HEAD"])
        guard output.succeeded else {
            throw ChronicleError("cannot resolve Git HEAD for file references")
        }
        guard let raw = String(data: output.stdout, encoding: .utf8) else {
            throw ChronicleError("git returned a non-UTF-8 commit SHA")
        }
        let sha = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count >= 7, sha.utf8.allSatisfy({ $0.isHexDigit }) else {
            throw ChronicleError("git returned an invalid commit SHA")
        }
        return sha
    }

    public static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private struct Output {
        var succeeded: Bool
        var stdout: Data
    }

    private static func run(_ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw ChronicleError("cannot run git: \(error.localizedDescription)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(succeeded: process.terminationStatus == 0, stdout: data)
    }
}

extension UInt8 {
    fileprivate var isHexDigit: Bool {
        (0x30...0x39).contains(self) || (0x61...0x66).contains(self) || (0x41...0x46).contains(self)
    }
}
