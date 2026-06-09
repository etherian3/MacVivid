import Foundation
import CoreGraphics

// MARK: - Gamma Watchdog

/// Background watchdog that keeps the gamma compensation active.
/// macOS ColorSync resets the gamma table periodically, so we need to
/// re-apply it continuously to maintain the fix.
enum GammaWatchdog {

    /// PID file location
    static let pidFile: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.macvivid/watchdog.pid"
    }()

    /// Config file with display info for the watchdog
    static let configFile: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.macvivid/watchdog.json"
    }()

    // MARK: - Watchdog Control

    /// Start the watchdog as a background process
    static func start(for displays: [DisplayInfo], intensity: ColorProfileGenerator.Intensity = .normal) -> Bool {
        // Stop any existing watchdog first
        stop()

        // Save display config for the watchdog process
        saveConfig(displays: displays, intensity: intensity)

        // Get the path to the macvivid binary
        let binaryPath = ProcessInfo.processInfo.arguments[0]

        // Launch self with --watch flag as a background process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["fix", "--watch"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Detach from terminal
        process.qualityOfService = .background

        do {
            try process.run()
            let pid = process.processIdentifier
            savePID(pid)
            Logger.debug("Watchdog started with PID: \(pid)")
            return true
        } catch {
            Logger.error("Failed to start watchdog: \(error)")
            return false
        }
    }

    /// Stop the running watchdog
    static func stop() {
        guard let pid = readPID() else { return }

        // Send SIGTERM
        kill(pid, SIGTERM)
        Logger.debug("Sent SIGTERM to watchdog PID: \(pid)")

        // Clean up PID file
        try? FileManager.default.removeItem(atPath: pidFile)
    }

    /// Check if watchdog is running
    static func isRunning() -> Bool {
        guard let pid = readPID() else { return false }
        // Check if process exists
        return kill(pid, 0) == 0
    }

    // MARK: - Watch Loop (called when running as watchdog)

    /// Run the gamma compensation loop
    /// This is called when `macvivid fix --watch` is invoked
    static func runWatchLoop() {
        // Load display config
        guard let displays = loadConfig() else {
            Logger.debug("Watchdog: No config found, exiting")
            return
        }

        // Save our PID
        savePID(getpid())

        // Set up signal handler for clean exit
        signal(SIGTERM) { _ in
            // Restore gamma on exit
            CGDisplayRestoreColorSyncSettings()
            try? FileManager.default.removeItem(atPath: GammaWatchdog.pidFile)
            exit(0)
        }

        signal(SIGINT) { _ in
            CGDisplayRestoreColorSyncSettings()
            try? FileManager.default.removeItem(atPath: GammaWatchdog.pidFile)
            exit(0)
        }

        // Load intensity from config
        let intensity = loadIntensity()

        // Initial apply
        for display in displays {
            _ = ColorProfileGenerator.applyGammaCompensation(for: display, intensity: intensity)
        }

        // Re-apply loop
        // Check every 2 seconds and re-apply if needed
        while true {
            Thread.sleep(forTimeInterval: 2.0)

            // Check if PID file still exists (used as stop signal)
            guard FileManager.default.fileExists(atPath: pidFile) else {
                CGDisplayRestoreColorSyncSettings()
                break
            }

            // Re-apply gamma for all configured displays
            for display in displays {
                _ = ColorProfileGenerator.applyGammaCompensation(for: display, intensity: intensity)
            }
        }
    }

    // MARK: - Config Management

    private static func saveConfig(displays: [DisplayInfo], intensity: ColorProfileGenerator.Intensity = .normal) {
        let configs = displays.map { display -> [String: Any] in
            return [
                "name": display.name,
                "displayID": Int(display.displayID),
                "vendorID": Int(display.vendorID),
                "productID": Int(display.productID),
                "width": display.resolution.width,
                "height": display.resolution.height,
                "refreshRate": display.resolution.refreshRate,
            ]
        }

        let data: [String: Any] = [
            "displays": configs,
            "intensity": intensity.rawValue
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            try? jsonData.write(to: URL(fileURLWithPath: configFile))
        }
    }

    private static func loadIntensity() -> ColorProfileGenerator.Intensity {
        guard let data = FileManager.default.contents(atPath: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = json["intensity"] as? String,
              let intensity = ColorProfileGenerator.Intensity(rawValue: rawValue) else {
            return .normal
        }
        return intensity
    }

    private static func loadConfig() -> [DisplayInfo]? {
        guard let data = FileManager.default.contents(atPath: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configs = json["displays"] as? [[String: Any]] else {
            return nil
        }

        return configs.compactMap { config -> DisplayInfo? in
            guard let name = config["name"] as? String,
                  let displayID = config["displayID"] as? Int,
                  let vendorID = config["vendorID"] as? Int,
                  let productID = config["productID"] as? Int,
                  let width = config["width"] as? Int,
                  let height = config["height"] as? Int,
                  let refreshRate = config["refreshRate"] as? Int else {
                return nil
            }

            return DisplayInfo(
                displayID: UInt32(displayID),
                name: name,
                vendorID: UInt32(vendorID),
                productID: UInt32(productID),
                serialNumber: 0,
                connectionType: .hdmi,
                resolution: Resolution(width: width, height: height, refreshRate: refreshRate),
                colorMode: ColorMode(encoding: .unknown, range: .unknown, bitDepth: 8),
                hdrEnabled: false,
                isExternal: true,
                isProtected: false,
                edidHex: nil
            )
        }
    }

    // MARK: - PID Management

    private static func savePID(_ pid: pid_t) {
        let dir = (pidFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(pid)".write(toFile: pidFile, atomically: true, encoding: .utf8)
    }

    private static func readPID() -> pid_t? {
        guard let content = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }
}
