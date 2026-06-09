import ArgumentParser
import Foundation

// MARK: - MacVivid CLI Entry Point

@main
struct MacVivid: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macvivid",
        abstract: "Fix washed out colors on external monitors connected to your Mac.",
        discussion: """
            MacVivid detects external monitors and fixes the common "washed out colors"
            problem caused by macOS using YCbCr/Limited Range instead of RGB Full Range.

            Quick Start:
              macvivid status    - Check your monitor's current color mode
              macvivid fix       - Fix washed out colors (one command!)
              macvivid protect   - Keep the fix after sleep/reboot
              macvivid revert    - Undo changes and restore original settings
            """,
        version: "0.1.0",
        subcommands: [
            StatusCommand.self,
            FixCommand.self,
            RevertCommand.self,
            ProtectCommand.self,
            UnprotectCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}
