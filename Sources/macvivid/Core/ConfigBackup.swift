import Foundation

// MARK: - Configuration Backup & Restore

/// Manages backup and restore of display configurations
enum ConfigBackup {

    /// Base directory for MacVivid data
    static var macvividDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.macvivid"
    }

    /// Directory for backups
    static var backupDir: String {
        return "\(macvividDir)/backups"
    }

    /// Directory for protection configs
    static var protectionDir: String {
        return "\(macvividDir)/protection"
    }

    // MARK: - Backup

    /// Create a full backup before making changes
    static func createBackup(displays: [DisplayInfo]) -> String? {
        let fm = FileManager.default
        let timestamp = timestampString()
        let backupPath = "\(backupDir)/\(timestamp)"

        do {
            try fm.createDirectory(atPath: backupPath, withIntermediateDirectories: true)
        } catch {
            Logger.error("Failed to create backup directory: \(error)")
            return nil
        }

        // Save display configuration as JSON
        let config = DisplayConfiguration(
            timestamp: Date(),
            displays: displays,
            plistBackupPath: nil,
            edidOverridePaths: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: "\(backupPath)/config.json"))
        } catch {
            Logger.error("Failed to save backup config: \(error)")
            return nil
        }

        // Backup windowserver plist
        if let plistBackup = ColorFixer.backupPlist(to: backupPath) {
            Logger.debug("Plist backed up to: \(plistBackup)")
        }

        // Backup existing EDID overrides
        for display in displays where display.isExternal {
            backupExistingEDIDOverride(display: display, to: backupPath)
        }

        // Save system profiler info
        let spResult = ShellRunner.run("system_profiler SPDisplaysDataType 2>/dev/null")
        if spResult.isSuccess {
            let spPath = "\(backupPath)/system_profiler_displays.txt"
            try? spResult.output.write(toFile: spPath, atomically: true, encoding: .utf8)
        }

        Logger.debug("Full backup saved to: \(backupPath)")
        return backupPath
    }

    // MARK: - Restore

    /// Restore from the most recent backup
    static func restoreLatest() -> Bool {
        guard let latestBackup = getLatestBackup() else {
            Logger.error("No backups found to restore from")
            return false
        }

        return restore(from: latestBackup)
    }

    /// Restore from a specific backup
    static func restore(from backupPath: String) -> Bool {
        let fm = FileManager.default

        guard fm.fileExists(atPath: backupPath) else {
            Logger.error("Backup not found at: \(backupPath)")
            return false
        }

        var success = true

        // Restore windowserver plist
        let plistFiles = (try? fm.contentsOfDirectory(atPath: backupPath))?.filter { $0.contains("com.apple.windowserver") } ?? []
        for plistFile in plistFiles {
            let backupPlist = "\(backupPath)/\(plistFile)"
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let plistDir = "\(home)/Library/Preferences/ByHost"
            let targetPlist = "\(plistDir)/\(plistFile)"

            do {
                if fm.fileExists(atPath: targetPlist) {
                    try fm.removeItem(atPath: targetPlist)
                }
                try fm.copyItem(atPath: backupPlist, toPath: targetPlist)
                Logger.debug("Restored plist: \(plistFile)")
            } catch {
                Logger.error("Failed to restore plist \(plistFile): \(error)")
                success = false
            }
        }

        // Load config to get display info for EDID cleanup
        let configPath = "\(backupPath)/config.json"
        if let configData = fm.contents(atPath: configPath) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            if let config = try? decoder.decode(DisplayConfiguration.self, from: configData) {
                for display in config.displays where display.isExternal {
                    // Remove EDID overrides installed by MacVivid
                    let _ = EDIDOverride.remove(for: display)
                }
            }
        }

        return success
    }

    // MARK: - List Backups

    /// Get all available backups, sorted by date (newest first)
    static func listBackups() -> [(path: String, date: String)] {
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: backupDir) else {
            return []
        }

        return contents
            .sorted(by: >)
            .map { (path: "\(backupDir)/\($0)", date: $0) }
    }

    /// Get the latest backup path
    static func getLatestBackup() -> String? {
        return listBackups().first?.path
    }

    // MARK: - Protection Config

    /// Save protection configuration for a display
    static func saveProtectionConfig(for display: DisplayInfo) -> Bool {
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: protectionDir, withIntermediateDirectories: true)
        } catch {
            Logger.error("Failed to create protection directory: \(error)")
            return false
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(display)
            let filePath = "\(protectionDir)/\(display.vendorIDHex)_\(display.productIDHex).json"
            try data.write(to: URL(fileURLWithPath: filePath))
            return true
        } catch {
            Logger.error("Failed to save protection config: \(error)")
            return false
        }
    }

    /// Remove protection configuration for a display
    static func removeProtectionConfig(for display: DisplayInfo) -> Bool {
        let filePath = "\(protectionDir)/\(display.vendorIDHex)_\(display.productIDHex).json"
        do {
            try FileManager.default.removeItem(atPath: filePath)
            return true
        } catch {
            Logger.debug("No protection config to remove: \(error)")
            return true
        }
    }

    /// Check if a display has protection config
    static func hasProtectionConfig(vendorID: UInt32, productID: UInt32) -> Bool {
        let vendorHex = String(format: "0x%04X", vendorID)
        let productHex = String(format: "0x%04X", productID)
        let filePath = "\(protectionDir)/\(vendorHex)_\(productHex).json"
        return FileManager.default.fileExists(atPath: filePath)
    }

    // MARK: - Helpers

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func backupExistingEDIDOverride(display: DisplayInfo, to backupPath: String) {
        let vendorHex = String(format: "%x", display.vendorID)
        let productHex = String(format: "%x", display.productID)
        let overrideFile = "\(EDIDOverride.overrideBasePath)/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"

        if FileManager.default.fileExists(atPath: overrideFile) {
            let backupFile = "\(backupPath)/edid_override_\(vendorHex)_\(productHex)"
            do {
                try FileManager.default.copyItem(atPath: overrideFile, toPath: backupFile)
                Logger.debug("Backed up existing EDID override: \(overrideFile)")
            } catch {
                Logger.debug("Could not backup EDID override: \(error)")
            }
        }
    }

    /// Ensure the macvivid directory exists
    static func ensureDirectories() {
        let fm = FileManager.default
        let dirs = [macvividDir, backupDir, protectionDir, "\(macvividDir)/logs"]

        for dir in dirs {
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }
}
