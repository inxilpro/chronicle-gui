import Foundation

/// Installs the CLI shim and the Claude skill per SPEC §6.
public enum SkillInstaller {
    public static let managedMarker = "<!-- installed-by-chronicle -->"

    /// Symlinks `executable` to `shim` (atomic temp + rename), backs up any
    /// unmanaged skill file, and writes the bundled template with
    /// `{{CHRONICLE_BIN}}` replaced by the shim's absolute path.
    @discardableResult
    public static func install(executable: URL, shim: URL, skill: URL) throws -> URL {
        try installShim(executable: executable, shim: shim)

        let existing: String?
        do {
            existing = try String(contentsOf: skill, encoding: .utf8)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
        {
            existing = nil
        } catch {
            throw ChronicleError(
                "cannot inspect the existing chronicle skill at \(skill.path): \(error.localizedDescription)")
        }
        if let existing, !existing.contains(managedMarker) {
            let backup = skill.deletingLastPathComponent()
                .appendingPathComponent("SKILL.md.before-chronicle-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: skill, to: backup)
            } catch {
                throw ChronicleError(
                    "cannot back up the existing chronicle skill to \(backup.path): \(error.localizedDescription)")
            }
        }
        let content = try template().replacingOccurrences(of: "{{CHRONICLE_BIN}}", with: shim.path)
        try writeAtomic(path: skill, content: Data(content.utf8))
        return skill
    }

    public static func integrationInstalled(shim: URL, skill: URL) -> Bool {
        FileManager.default.fileExists(atPath: shim.path)
            && FileManager.default.fileExists(atPath: skill.path)
    }

    public static func template() throws -> String {
        guard let url = Bundle.module.url(forResource: "SKILL", withExtension: "md"),
            let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw ChronicleError("the bundled chronicle skill template is missing")
        }
        return content
    }

    private static func installShim(executable: URL, shim: URL) throws {
        let parent = shim.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ChronicleError("cannot create \(parent.path): \(error.localizedDescription)")
        }
        let temporary = parent.appendingPathComponent(".chronicle-shim-\(UUID().uuidString)")
        do {
            try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: executable)
            // rename(2) replaces an existing shim atomically; FileManager's
            // moveItem refuses to overwrite.
            guard rename(temporary.path, shim.path) == 0 else {
                throw ChronicleError(String(cString: strerror(errno)))
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            let detail = (error as? ChronicleError)?.message ?? error.localizedDescription
            throw ChronicleError("cannot install CLI at \(shim.path): \(detail)")
        }
    }

    private static func writeAtomic(path: URL, content: Data) throws {
        let parent = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ChronicleError("cannot create \(parent.path): \(error.localizedDescription)")
        }
        let temporary = parent.appendingPathComponent(".SKILL.md.chronicle-\(UUID().uuidString)")
        do {
            try content.write(to: temporary)
            guard rename(temporary.path, path.path) == 0 else {
                throw ChronicleError(String(cString: strerror(errno)))
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            let detail = (error as? ChronicleError)?.message ?? error.localizedDescription
            throw ChronicleError("cannot install \(path.path): \(detail)")
        }
    }
}
