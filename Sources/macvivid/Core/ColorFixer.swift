import Foundation

// MARK: - Color Fixer

/// Applies RGB Full Range fix using multiple methods for Apple Silicon compatibility
enum ColorFixer {

    // MARK: - Public API

    /// Apply RGB Full Range fix for a display — uses multiple methods
    /// Method 1 (Gamma) takes effect IMMEDIATELY, no restart needed.
    static func applyRGBFullRange(for display: DisplayInfo) -> Bool {
        Logger.debug("Applying RGB Full Range fix for: \(display.name)")

        var anySuccess = false
        var results: [(method: String, success: Bool)] = []

        // Method 1: GAMMA COMPENSATION (INSTANT EFFECT!)
        // Uses CGSetDisplayTransferByTable to expand limited range → full range
        // This is the primary fix — takes effect IMMEDIATELY
        Logger.debug("Method 1: Gamma compensation (CGSetDisplayTransferByTable)...")
        let gammaSuccess = ColorProfileGenerator.applyGammaCompensation(for: display)
        results.append(("Gamma Fix", gammaSuccess))
        if gammaSuccess { anySuccess = true }

        // Method 2: ICC Color Profile (backup, user can select manually if gamma resets)
        Logger.debug("Method 2: ICC Color Profile (backup)...")
        let profileSuccess = ColorProfileGenerator.installFullRangeProfile(for: display)
        results.append(("ICC Profile", profileSuccess))
        if profileSuccess { anySuccess = true }

        // Method 3: Install EDID override (persistent after restart, requires sudo)
        Logger.debug("Method 3: EDID Override...")
        let edidSuccess = EDIDOverride.install(for: display)
        results.append(("EDID Override", edidSuccess))
        if edidSuccess { anySuccess = true }

        // Method 4: Modify windowserver plist (add LinkDescription)
        Logger.debug("Method 4: WindowServer plist modification...")
        let plistSuccess = modifyWindowServerPlist(for: display)
        results.append(("Plist Mod", plistSuccess))
        if plistSuccess { anySuccess = true }

        // Log results
        for r in results {
            Logger.debug("  \(r.method): \(r.success ? "✅" : "❌")")
        }

        return anySuccess
    }

    /// Revert color mode changes
    static func revert(for display: DisplayInfo, backupPath: String?) -> Bool {
        Logger.debug("Reverting color fix for: \(display.name)")

        var success = true

        // Remove EDID override
        if !EDIDOverride.remove(for: display) {
            success = false
        }

        // Restore plist backup if available
        if let backup = backupPath {
            if !restorePlistBackup(from: backup) {
                success = false
            }
        }

        return success
    }

    // MARK: - Method 2: WindowServer Plist Modification

    private static func modifyWindowServerPlist(for display: DisplayInfo) -> Bool {
        guard let plistPath = getWindowServerPlistPath() else {
            Logger.debug("No windowserver plist found")
            return false
        }

        Logger.debug("Found windowserver plist: \(plistPath)")

        // Convert to XML for editing
        let convertResult = ShellRunner.run("plutil -convert xml1 '\(plistPath)' 2>/dev/null")
        if !convertResult.isSuccess {
            Logger.debug("Failed to convert plist to XML: \(convertResult.error)")
            return false
        }

        // Read the plist content
        guard let plistData = FileManager.default.contents(atPath: plistPath),
              var plistDict = try? PropertyListSerialization.propertyList(from: plistData, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] else {
            Logger.debug("Failed to read plist content")
            return false
        }

        var modified = false

        // The macOS 15 / Apple Silicon plist structure:
        // DisplaySets (dict) > Configs (array) > [n] (dict) > DisplayConfig (array) > [n] (dict) > UUID, CurrentInfo
        if var displaySets = plistDict["DisplaySets"] as? [String: Any],
           var configs = displaySets["Configs"] as? [[String: Any]] {

            for (configIdx, var config) in configs.enumerated() {
                if var displayConfig = config["DisplayConfig"] as? [[String: Any]] {
                    for (dispIdx, var disp) in displayConfig.enumerated() {
                        // Only modify external display entries (1920x1080 or matching UUID)
                        if let currentInfo = disp["CurrentInfo"] as? [String: Any],
                           let high = currentInfo["High"] as? Double,
                           let wide = currentInfo["Wide"] as? Double {

                            let isExternalDisplay = (Int(wide) == display.resolution.width && Int(high) == display.resolution.height) ||
                                                    (Int(wide) == 1920 && Int(high) == 1080) ||
                                                    (Int(wide) == 3840 && Int(high) == 2160)

                            if isExternalDisplay {
                                // Add/modify LinkDescription to force RGB Full Range
                                disp["LinkDescription"] = [
                                    "PixelEncoding": 0,   // 0 = RGB
                                    "Range": 0,           // 0 = Full Range
                                    "BitDepth": 8,
                                    "BitsPerColorComponent": 8
                                ] as [String : Any]

                                displayConfig[dispIdx] = disp
                                modified = true
                                Logger.debug("Added LinkDescription to display config at [\(configIdx)][\(dispIdx)]")
                            }
                        }
                    }
                    config["DisplayConfig"] = displayConfig
                    configs[configIdx] = config
                }
            }

            if modified {
                displaySets["Configs"] = configs
                plistDict["DisplaySets"] = displaySets
            }
        }

        // Also try the legacy format (DisplaySets as array > Displays)
        if !modified {
            if var displaySets = plistDict["DisplaySets"] as? [[String: Any]] {
                for (setIndex, var displaySet) in displaySets.enumerated() {
                    if var displays = displaySet["Displays"] as? [[String: Any]] {
                        for (dispIndex, var disp) in displays.enumerated() {
                            if var linkDesc = disp["LinkDescription"] as? [String: Any] {
                                linkDesc["PixelEncoding"] = 0
                                linkDesc["Range"] = 0
                                disp["LinkDescription"] = linkDesc
                            } else {
                                disp["LinkDescription"] = [
                                    "PixelEncoding": 0,
                                    "Range": 0,
                                    "BitDepth": 8
                                ] as [String : Any]
                            }
                            displays[dispIndex] = disp
                            modified = true
                        }
                        displaySet["Displays"] = displays
                        displaySets[setIndex] = displaySet
                    }
                }
                if modified {
                    plistDict["DisplaySets"] = displaySets
                }
            }
        }

        if modified {
            do {
                let newData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
                try newData.write(to: URL(fileURLWithPath: plistPath))
                ShellRunner.run("plutil -convert binary1 '\(plistPath)' 2>/dev/null")
                Logger.debug("Successfully modified windowserver plist")
                return true
            } catch {
                Logger.debug("Failed to write modified plist: \(error)")
                return false
            }
        }

        Logger.debug("No matching display configuration found in plist")
        return false
    }

    // MARK: - Method 3: ColorSync Preferences

    private static func setColorSyncPreferences(for display: DisplayInfo) -> Bool {
        // Set display to use sRGB profile (full range RGB)
        let commands = [
            "defaults write com.apple.CoreDisplay useForcedHDR -bool false",
            "defaults write com.apple.CoreDisplay useHDR -bool false",
        ]

        var anySuccess = false
        for cmd in commands {
            let result = ShellRunner.run(cmd)
            if result.isSuccess {
                anySuccess = true
            }
        }

        return anySuccess
    }

    // MARK: - Backup & Restore

    /// Get the path to the current windowserver plist
    static func getWindowServerPlistPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistDir = "\(home)/Library/Preferences/ByHost"
        let result = ShellRunner.run("ls \(plistDir)/com.apple.windowserver.displays.*.plist 2>/dev/null | head -1")
        if result.isSuccess && !result.output.isEmpty {
            return result.output
        }
        // Fallback to older plist name
        let result2 = ShellRunner.run("ls \(plistDir)/com.apple.windowserver.*.plist 2>/dev/null | head -1")
        return result2.isSuccess && !result2.output.isEmpty ? result2.output : nil
    }

    /// Backup the current windowserver plist
    static func backupPlist(to backupDir: String) -> String? {
        guard let plistPath = getWindowServerPlistPath() else {
            Logger.debug("No windowserver plist to backup")
            return nil
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: backupDir) {
            try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        }

        let plistName = (plistPath as NSString).lastPathComponent
        let backupPath = "\(backupDir)/\(plistName)"

        do {
            if fm.fileExists(atPath: backupPath) {
                try fm.removeItem(atPath: backupPath)
            }
            try fm.copyItem(atPath: plistPath, toPath: backupPath)
            Logger.debug("Plist backed up to: \(backupPath)")
            return backupPath
        } catch {
            Logger.debug("Failed to backup plist: \(error)")
            return nil
        }
    }

    /// Restore a plist from backup
    private static func restorePlistBackup(from backupPath: String) -> Bool {
        guard let plistPath = getWindowServerPlistPath() else {
            return false
        }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: plistPath) {
                try fm.removeItem(atPath: plistPath)
            }
            try fm.copyItem(atPath: backupPath, toPath: plistPath)
            Logger.debug("Plist restored from backup: \(backupPath)")
            return true
        } catch {
            Logger.debug("Failed to restore plist backup: \(error)")
            return false
        }
    }
}
