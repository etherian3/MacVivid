import ArgumentParser
import Foundation

// MARK: - Protect Command

struct ProtectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "protect",
        abstract: "Protect the current fix so it survives sleep, reconnect, and reboot."
    )

    @Option(name: .shortAndLong, help: "Target a specific monitor by name.")
    var monitor: String?

    @Flag(name: .shortAndLong, help: "Show verbose debug output.")
    var verbose = false

    mutating func run() throws {
        Logger.setup(verbose: verbose)
        ConfigBackup.ensureDirectories()

        print("")
        print("\(Emoji.shield) " + "MacVivid Protect".styled(.bold, .brightCyan) + " — Securing your color settings...")
        print("")

        let externalDisplays = DisplayDetector.detectExternal()

        if externalDisplays.isEmpty {
            Logger.error("No external monitors detected!")
            return
        }

        // Determine which displays to protect
        let displaysToProtect: [DisplayInfo]

        if let monitorName = monitor {
            guard let display = DisplayDetector.findDisplay(named: monitorName) else {
                Logger.error("Monitor '\(monitorName)' not found.")
                return
            }
            displaysToProtect = [display]
        } else {
            displaysToProtect = externalDisplays
        }

        for display in displaysToProtect {
            protectDisplay(display)
        }

        // Install LaunchAgent for auto-fix on reconnect
        installLaunchAgent()

        print("")
        print(String(repeating: "═", count: 56).colored(.green))
        print("\(Emoji.lock) " + "Protection activated!".styled(.bold, .green))
        print("")
        print("\(Emoji.lightbulb) " + "Your color settings will now persist through:".colored(.cyan))
        print("   • Sleep / Wake")
        print("   • Cable reconnect")
        print("   • System reboot")
        print("")
        print("   Run " + "'macvivid unprotect'".bold() + " to remove protection.")
        print("")
    }

    // MARK: - Protect Display

    private func protectDisplay(_ display: DisplayInfo) {
        print("  \(Emoji.monitor) " + "Protecting: ".colored(.cyan) + display.name.bold())

        // Step 1: Ensure EDID override is installed
        if !EDIDOverride.exists(for: display) {
            print("    Installing EDID override...")
            let success = EDIDOverride.install(for: display)
            print(success ? "    \(Emoji.check) EDID override installed".colored(.green)
                         : "    \(Emoji.warning) Could not install EDID override".colored(.yellow))
        } else {
            print("    \(Emoji.check) EDID override already installed".colored(.green))
        }

        // Step 2: Save protection config
        let configSaved = ConfigBackup.saveProtectionConfig(for: display)
        print(configSaved ? "    \(Emoji.check) Protection config saved".colored(.green)
                          : "    \(Emoji.warning) Could not save protection config".colored(.yellow))

        print("")
    }

    // MARK: - LaunchAgent

    private func installLaunchAgent() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agentDir = "\(home)/Library/LaunchAgents"
        let agentPath = "\(agentDir)/com.macvivid.protect.plist"

        // Find the macvivid binary location
        let binaryPath = ProcessInfo.processInfo.arguments[0]

        let agentPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.macvivid.protect</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>fix</string>
                <string>--all</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>WatchPaths</key>
            <array>
                <string>/Library/Displays</string>
            </array>
            <key>StandardOutPath</key>
            <string>\(home)/.macvivid/logs/launchagent.log</string>
            <key>StandardErrorPath</key>
            <string>\(home)/.macvivid/logs/launchagent_error.log</string>
        </dict>
        </plist>
        """

        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: agentDir) {
                try fm.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
            }
            try agentPlist.write(toFile: agentPath, atomically: true, encoding: .utf8)

            // Load the agent
            ShellRunner.run("launchctl unload '\(agentPath)' 2>/dev/null")
            let loadResult = ShellRunner.run("launchctl load '\(agentPath)'")

            if loadResult.isSuccess {
                Logger.debug("LaunchAgent installed and loaded: \(agentPath)")
            } else {
                Logger.debug("LaunchAgent installed but couldn't load: \(loadResult.error)")
            }
        } catch {
            Logger.debug("Failed to install LaunchAgent: \(error)")
        }
    }
}
