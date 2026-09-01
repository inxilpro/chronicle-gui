import Foundation
import Testing
@testable import ChronicleKit

@Suite struct SkillInstallerTests {
    @Test func bundledSkillHasValidIdentityAndSessionContract() throws {
        let template = try SkillInstaller.template()
        #expect(template.contains(SkillInstaller.managedMarker))
        #expect(template.contains("{{CHRONICLE_BIN}}"))
    }

    @Test func installerCreatesStableShimAndManagedSkill() throws {
        let home = try TestHome()
        let executable = home.scratch("Chronicle")
        try "test executable".write(to: executable, atomically: true, encoding: .utf8)
        #expect(!home.store.integrationInstalled())

        let skill = try SkillInstaller.install(
            executable: executable, shim: home.paths.shimURL, skill: home.paths.skillURL)
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: home.paths.shimURL.path)
        #expect(destination == executable.path)
        let content = try String(contentsOf: skill, encoding: .utf8)
        #expect(content.contains(SkillInstaller.managedMarker))
        #expect(content.contains(home.paths.shimURL.path))
        #expect(!content.contains("{{CHRONICLE_BIN}}"))
        #expect(SkillInstaller.integrationInstalled(shim: home.paths.shimURL, skill: home.paths.skillURL))
        #expect(home.store.integrationInstalled())

        // Reinstall over an existing shim replaces it atomically.
        try SkillInstaller.install(
            executable: executable, shim: home.paths.shimURL, skill: home.paths.skillURL)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: home.paths.shimURL.path)
                == executable.path)
    }

    @Test func installerBacksUpAnExistingUnmanagedSkill() throws {
        let home = try TestHome()
        let executable = home.scratch("Chronicle")
        try "test executable".write(to: executable, atomically: true, encoding: .utf8)
        let skillDirectory = home.paths.skillURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "original skill".write(to: home.paths.skillURL, atomically: true, encoding: .utf8)

        let skill = try SkillInstaller.install(
            executable: executable, shim: home.paths.shimURL, skill: home.paths.skillURL)
        #expect(try String(contentsOf: skill, encoding: .utf8).contains(SkillInstaller.managedMarker))
        let backups = try FileManager.default.contentsOfDirectory(atPath: skillDirectory.path)
            .filter { $0.hasPrefix("SKILL.md.before-chronicle-") }
        #expect(backups.count == 1)
        let backupContent = try String(
            contentsOf: skillDirectory.appendingPathComponent(backups[0]), encoding: .utf8)
        #expect(backupContent == "original skill")
    }

    @Test func installerDoesNotBackUpItsOwnManagedSkill() throws {
        let home = try TestHome()
        let executable = home.scratch("Chronicle")
        try "test executable".write(to: executable, atomically: true, encoding: .utf8)
        try SkillInstaller.install(
            executable: executable, shim: home.paths.shimURL, skill: home.paths.skillURL)
        try SkillInstaller.install(
            executable: executable, shim: home.paths.shimURL, skill: home.paths.skillURL)
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: home.paths.skillURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("SKILL.md.before-chronicle-") }
        #expect(backups.isEmpty)
    }
}
