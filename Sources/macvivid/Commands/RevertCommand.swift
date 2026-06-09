import ArgumentParser
import Foundation

// MARK: - Revert Command

struct RevertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revert",
        abstract: "Revert all changes and restore original display settings."
    )

    @Option(name: .shortAndLong, help: "Target a specific monitor by name.")
    var monitor: String?

    @Flag(name: .long, help: "List all available backups.")
    var list = false

    @Option(name: .long, help: "Restore from a specific backup (by timestamp).")
    var backup: String?

    @Flag(name: .shortAndLong, help: "Show verbose debug output.")
    var verbose = false

    mutating func run() throws {
        Logger.setup(verbose: verbose)
        ConfigBackup.ensureDirectories()

        if list {
            listBackups()
            return
        }

        print("")
        print("\(Emoji.revert) " + "MacVivid Revert".styled(.bold, .brightCyan) + " — Restoring original settings...")
        print("")

        // Determine which backup to restore from
        let backupPath: String

        if let specificBackup = backup {
            backupPath = "\(ConfigBackup.backupDir)/\(specificBackup)"
            guard FileManager.default.fileExists(atPath: backupPath) else {
                Logger.error("Backup '\(specificBackup)' not found.")
                Logger.info("Run 'macvivid revert --list' to see available backups.")
                return
            }
        } else {
            guard let latest = ConfigBackup.getLatestBackup() else {
                Logger.error("No backups found!")
                Logger.info("MacVivid creates backups automatically when you run 'macvivid fix'.")
                return
            }
            backupPath = latest
        }

        let shortPath = backupPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        print("\(Emoji.save) " + "Restoring from: ".colored(.cyan) + shortPath.bold())
        print("")

        // Step 1: Stop watchdog (must be FIRST, otherwise it re-applies gamma)
        print("  [1/5] " + "Stopping watchdog...".colored(.cyan))
        if GammaWatchdog.isRunning() {
            GammaWatchdog.stop()
            print("  \(Emoji.check) " + "Watchdog stopped".colored(.green))
        } else {
            print("  \(Emoji.info) " + "No watchdog running".colored(.dim))
        }

        // Step 2: Restore default gamma (instant undo of visual fix)
        print("  [2/5] " + "Restoring default gamma...".colored(.cyan))
        ColorProfileGenerator.restoreAllGamma()
        print("  \(Emoji.check) " + "Gamma restored to default".colored(.green))

        // Step 3: Remove EDID overrides
        print("  [3/5] " + "Removing EDID overrides...".colored(.cyan))
        let externalDisplays = DisplayDetector.detectExternal()

        if let monitorName = monitor {
            if let display = DisplayDetector.findDisplay(named: monitorName) {
                let removed = EDIDOverride.remove(for: display)
                print(removed ? "  \(Emoji.check) EDID override removed for \(display.name)".colored(.green)
                             : "  \(Emoji.info) No EDID override found for \(display.name)".colored(.dim))
                // Also remove ICC profile
                ColorProfileGenerator.removeProfile(for: display)
            } else {
                Logger.warning("Monitor '\(monitorName)' not found")
            }
        } else {
            for display in externalDisplays {
                let removed = EDIDOverride.remove(for: display)
                if removed {
                    print("  \(Emoji.check) " + "EDID override removed for \(display.name)".colored(.green))
                }
                ColorProfileGenerator.removeProfile(for: display)
            }
            if externalDisplays.isEmpty {
                print("  \(Emoji.info) " + "No external displays to clean up".colored(.dim))
            }
        }

        // Step 4: Restore plist backup
        print("  [4/5] " + "Restoring WindowServer configuration...".colored(.cyan))
        let plistRestored = ConfigBackup.restore(from: backupPath)
        print(plistRestored ? "  \(Emoji.check) WindowServer plist restored".colored(.green)
                            : "  \(Emoji.warning) Could not restore plist (may not have been modified)".colored(.yellow))

        // Step 5: Remove protection configs
        print("  [5/5] " + "Removing protection configs...".colored(.cyan))
        for display in externalDisplays {
            let _ = ConfigBackup.removeProtectionConfig(for: display)
        }
        print("  \(Emoji.check) " + "Protection configs cleaned up".colored(.green))

        // Done
        print("")
        print(String(repeating: "═", count: 56).colored(.green))
        print("\(Emoji.check) " + "Revert complete!".styled(.bold, .green))
        print("")
        print("\(Emoji.lightbulb) " + "Tips:".bold())
        print("   • " + "Log out and back in".bold() + " or " + "restart".bold() + " for changes to fully take effect.")
        print("   • EDID override removal requires a restart to take effect.")
        print("   • Run " + "'macvivid status'".bold() + " to verify the current state.")
        print("")
    }

    // MARK: - List Backups

    private func listBackups() {
        let backups = ConfigBackup.listBackups()

        if backups.isEmpty {
            Logger.info("No backups found.")
            Logger.info("MacVivid creates backups automatically when you run 'macvivid fix'.")
            return
        }

        print("")
        print("\(Emoji.save) " + "Available Backups:".styled(.bold, .cyan))
        print("")

        for (index, backup) in backups.enumerated() {
            let marker = index == 0 ? " (latest)".colored(.green) : ""
            let shortPath = backup.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            print("  \(index + 1). \(backup.date)\(marker)")
            print("     \(shortPath)".colored(.dim))
        }

        print("")
        print("\(Emoji.lightbulb) " + "To restore from a specific backup:".colored(.cyan))
        print("   macvivid revert --backup <timestamp>")
        print("")
    }
}
