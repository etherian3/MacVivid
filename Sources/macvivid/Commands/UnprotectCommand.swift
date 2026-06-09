import ArgumentParser
import Foundation

// MARK: - Unprotect Command

struct UnprotectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unprotect",
        abstract: "Remove protection and let macOS auto-detect display settings."
    )

    @Option(name: .shortAndLong, help: "Target a specific monitor by name.")
    var monitor: String?

    @Flag(name: .shortAndLong, help: "Show verbose debug output.")
    var verbose = false

    mutating func run() throws {
        Logger.setup(verbose: verbose)
        ConfigBackup.ensureDirectories()

        print("")
        print("\(Emoji.unlock) " + "MacVivid Unprotect".styled(.bold, .brightCyan) + " — Removing protection...")
        print("")

        let externalDisplays = DisplayDetector.detectExternal()

        // Determine which displays to unprotect
        let displaysToUnprotect: [DisplayInfo]

        if let monitorName = monitor {
            if let display = DisplayDetector.findDisplay(named: monitorName) {
                displaysToUnprotect = [display]
            } else {
                Logger.error("Monitor '\(monitorName)' not found.")
                return
            }
        } else {
            displaysToUnprotect = externalDisplays
        }

        // Step 1: Remove EDID overrides
        print("  [1/3] " + "Removing EDID overrides...".colored(.cyan))
        for display in displaysToUnprotect {
            let removed = EDIDOverride.remove(for: display)
            if removed {
                print("  \(Emoji.check) " + "EDID override removed for \(display.name)".colored(.green))
            }
        }
        if displaysToUnprotect.isEmpty {
            print("  \(Emoji.info) " + "No displays to unprotect".colored(.dim))
        }

        // Step 2: Remove protection configs
        print("  [2/3] " + "Removing protection configs...".colored(.cyan))
        for display in displaysToUnprotect {
            let _ = ConfigBackup.removeProtectionConfig(for: display)
        }
        print("  \(Emoji.check) " + "Protection configs removed".colored(.green))

        // Step 3: Remove LaunchAgent
        print("  [3/3] " + "Removing LaunchAgent...".colored(.cyan))
        removeLaunchAgent()
        print("  \(Emoji.check) " + "LaunchAgent removed".colored(.green))

        // Done
        print("")
        print(String(repeating: "═", count: 56).colored(.green))
        print("\(Emoji.unlock) " + "Protection removed!".styled(.bold, .green))
        print("")
        print("\(Emoji.lightbulb) " + "Tips:".bold())
        print("   • macOS will now auto-detect display settings on reconnect.")
        print("   • " + "Restart".bold() + " for EDID override removal to take full effect.")
        print("   • If colors become washed out again, run " + "'macvivid fix'".bold() + ".")
        print("")
    }

    // MARK: - Remove LaunchAgent

    private func removeLaunchAgent() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agentPath = "\(home)/Library/LaunchAgents/com.macvivid.protect.plist"

        // Unload first
        ShellRunner.run("launchctl unload '\(agentPath)' 2>/dev/null")

        // Remove the file
        try? FileManager.default.removeItem(atPath: agentPath)

        Logger.debug("LaunchAgent removed: \(agentPath)")
    }
}
