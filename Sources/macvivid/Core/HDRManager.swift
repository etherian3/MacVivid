import Foundation

// MARK: - HDR Manager

/// Manages HDR (High Dynamic Range) settings for external displays
enum HDRManager {

    // MARK: - Public API

    /// Disable HDR for external displays
    static func disableHDR(for display: DisplayInfo) -> Bool {
        Logger.debug("Checking HDR status for: \(display.name)")

        guard display.hdrEnabled else {
            Logger.debug("HDR is not enabled for \(display.name), skipping")
            return true
        }

        Logger.debug("Attempting to disable HDR for: \(display.name)")

        // Method 1: Try via defaults command
        if disableHDRViaDefaults() {
            return true
        }

        // Method 2: Try via windowserver plist modification
        if disableHDRViaPlist(displayID: display.displayID) {
            return true
        }

        // Method 3: Provide instructions for manual disable
        Logger.warning("Could not automatically disable HDR.")
        Logger.info("Please manually disable HDR:")
        Logger.info("  System Settings → Displays → Select your monitor → Uncheck 'High Dynamic Range'")

        return false
    }

    /// Re-enable HDR for a display (used during revert)
    static func enableHDR(for display: DisplayInfo) -> Bool {
        // HDR re-enable is best done manually since it depends on cable/monitor support
        Logger.info("To re-enable HDR, go to:")
        Logger.info("  System Settings → Displays → Select your monitor → Check 'High Dynamic Range'")
        return true
    }

    /// Check if HDR is currently enabled for any external display
    static func isHDREnabled() -> Bool {
        // Check system_profiler
        let result = ShellRunner.run("system_profiler SPDisplaysDataType 2>/dev/null | grep -i 'HDR'")
        if result.isSuccess {
            let output = result.output.lowercased()
            return output.contains("yes") || output.contains("enabled")
        }
        return false
    }

    // MARK: - Private Methods

    private static func disableHDRViaDefaults() -> Bool {
        // Try common defaults keys for HDR
        let commands = [
            "defaults write com.apple.CoreDisplay useForcedHDR -bool false",
            "defaults write com.apple.CoreDisplay useHDR -bool false",
        ]

        var anySuccess = false
        for cmd in commands {
            let result = ShellRunner.run(cmd)
            if result.isSuccess {
                anySuccess = true
                Logger.debug("HDR defaults written: \(cmd)")
            }
        }

        return anySuccess
    }

    private static func disableHDRViaPlist(displayID: UInt32) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistDir = "\(home)/Library/Preferences/ByHost"

        // Find windowserver plist
        let result = ShellRunner.run("ls \(plistDir)/com.apple.windowserver.*.plist 2>/dev/null | head -1")
        guard result.isSuccess, !result.output.isEmpty else {
            return false
        }

        let plistPath = result.output

        // Convert and read
        ShellRunner.run("plutil -convert xml1 '\(plistPath)' 2>/dev/null")

        guard let plistData = FileManager.default.contents(atPath: plistPath),
              var plistDict = try? PropertyListSerialization.propertyList(from: plistData, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] else {
            return false
        }

        var modified = false

        // Look for HDR-related keys
        if var displaySets = plistDict["DisplaySets"] as? [[String: Any]] {
            for (setIndex, var displaySet) in displaySets.enumerated() {
                if var displays = displaySet["Displays"] as? [[String: Any]] {
                    for (dispIndex, var disp) in displays.enumerated() {
                        if var linkDesc = disp["LinkDescription"] as? [String: Any] {
                            linkDesc["HDR"] = false
                            linkDesc["HDRMode"] = 0
                            disp["LinkDescription"] = linkDesc
                            displays[dispIndex] = disp
                            modified = true
                        }
                    }
                    displaySet["Displays"] = displays
                    displaySets[setIndex] = displaySet
                }
            }
            if modified {
                plistDict["DisplaySets"] = displaySets
            }
        }

        if modified {
            do {
                let newData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
                try newData.write(to: URL(fileURLWithPath: plistPath))
                ShellRunner.run("plutil -convert binary1 '\(plistPath)' 2>/dev/null")
                return true
            } catch {
                return false
            }
        }

        return false
    }
}
