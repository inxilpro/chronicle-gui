import ArgumentParser
import ChronicleKit

public struct ChronicleCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "chronicle",
        abstract: "Follow a Tuple planning call, keep the handoff, and speak through Chronicle.",
        discussion: """
        Chronicle stores operational data in ~/Library/Application Support/Chronicle. The active
        Tuple call ID is the session ID. Run `session attach` from the repository being planned;
        it returns the internal handoff path. No command writes a sidecar or handoff into the
        repository.
        """
    )

    public init() {}
}

/// Entry point for the `chronicle` executable target, which does not import ArgumentParser itself.
public enum ChronicleCLI {
    public static func main() {
        ChronicleCommand.main()
    }
}
