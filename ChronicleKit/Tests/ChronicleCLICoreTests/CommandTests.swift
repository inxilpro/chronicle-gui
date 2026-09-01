import Testing
@testable import ChronicleCLICore

@Suite struct CommandConfigurationTests {
    @Test func commandIsNamedChronicle() {
        #expect(ChronicleCommand.configuration.commandName == "chronicle")
    }
}
