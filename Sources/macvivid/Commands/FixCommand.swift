import ArgumentParser
import Foundation

// MARK: - Fix Command

struct FixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Fix washed out colors on external monitor(s)."
    )

    @Option(name: .shortAndLong, help: "Target a specific monitor by name (partial match).")
    var monitor: String?

    @Flag(name: .long, help: "Fix all external monitors.")
    var all = false

    @Flag(name: .long, help: "Preview changes without applying them.")
    var dryRun = false

    @Option(name: .shortAndLong, help: "Fix intensity: light, normal (default), or strong.")
    var intensity: String = "normal"

    @Flag(name: .long, help: .hidden)
    var watch = false

    @Flag(name: .shortAndLong, help: "Show verbose debug output.")
    var verbose = false

    mutating func run() throws {
        Logger.setup(verbose: verbose, logToFile: true)
        ConfigBackup.ensureDirectories()

        // Parse intensity
        let fixIntensity = ColorProfileGenerator.Intensity(rawValue: intensity) ?? .normal

        // Hidden --watch mode: run as background watchdog
        if watch {
            GammaWatchdog.runWatchLoop()
            return
        }

        printFixHeader()

        // Detect displays
        let externalDisplays = DisplayDetector.detectExternal()

        if externalDisplays.isEmpty {
            Logger.error("No external monitors detected!")
            Logger.info("Make sure your external monitor is connected and powered on.")
            Logger.info("Try disconnecting and reconnecting the cable, then run again.")
            return
        }

        // Determine which displays to fix
        let displaysToFix: [DisplayInfo]

        if let monitorName = monitor {
            guard let display = DisplayDetector.findDisplay(named: monitorName) else {
                Logger.error("Monitor '\(monitorName)' not found.")
                Logger.info("Available monitors:")
                for d in externalDisplays {
                    Logger.info("  - \(d.name)")
                }
                return
            }
            displaysToFix = [display]
        } else if all || externalDisplays.count == 1 {
            displaysToFix = externalDisplays
        } else {
            Logger.info("Multiple external monitors detected:")
            for (index, d) in externalDisplays.enumerated() {
                print("  \(index + 1). \(d.name) (\(d.connectionType.rawValue))")
            }
            Logger.info("Use '--monitor <name>' to target a specific monitor, or '--all' to fix all.")
            return
        }

        // Dry run mode
        if dryRun {
            printDryRun(displaysToFix)
            return
        }

        // Fix each display
        for display in displaysToFix {
            fixDisplay(display, intensity: fixIntensity)
        }

        // Start watchdog to keep gamma fix active
        print("\(Emoji.shield) " + "Starting background watchdog...".colored(.cyan))
        if GammaWatchdog.start(for: displaysToFix, intensity: fixIntensity) {
            print("\(Emoji.check) " + "Watchdog running — gamma fix will persist!".colored(.green))
        } else {
            print("\(Emoji.warning) " + "Could not start watchdog. Gamma may reset after a few seconds.".colored(.yellow))
        }
        print("")
    }

    // MARK: - Fix Header

    private func printFixHeader() {
        print("")
        print("\(Emoji.wrench) " + "MacVivid Fix".styled(.bold, .brightCyan) + " — Starting...")
        if dryRun {
            print("\(Emoji.info) " + "DRY RUN MODE".styled(.bold, .yellow) + " — No changes will be applied.".colored(.yellow))
        }
        print("")
    }

    // MARK: - Dry Run

    private func printDryRun(_ displays: [DisplayInfo]) {
        print(String(repeating: "─", count: 56).colored(.dim))
        print("\(Emoji.search) " + "Dry Run Preview:".bold())
        print("")

        for display in displays {
            print("  \(Emoji.monitor) \(display.name)".bold())
            print("    Current: \(display.colorMode.description)")
            print("    Target:  RGB Full Range 8-bit".colored(.green))
            print("")

            print("    Changes that would be applied:".colored(.cyan))
            print("    \(Emoji.check) Apply gamma compensation (instant effect)")
            print("    \(Emoji.check) Start background watchdog to maintain fix")

            if display.hdrEnabled {
                print("    \(Emoji.check) Disable HDR")
            }
            print("")
        }

        print("\(Emoji.lightbulb) " + "To apply these changes, run: ".colored(.cyan) + "'macvivid fix'".bold())
        print("")
    }

    // MARK: - Fix Display

    private func fixDisplay(_ display: DisplayInfo, intensity: ColorProfileGenerator.Intensity) {
        print("\(Emoji.monitor) " + "Target: ".colored(.cyan) + display.name.bold() + " (\(display.connectionType.rawValue))".colored(.dim))
        print("   Intensity: " + intensity.rawValue.styled(.bold, .brightCyan))
        print("")

        // Step 0: Create backup
        print("\(Emoji.save) " + "Creating backup...".colored(.cyan))
        if let backupPath = ConfigBackup.createBackup(displays: [display]) {
            let shortPath = backupPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            Logger.success("Backup saved: \(shortPath)")
        } else {
            Logger.warning("Could not create backup. Proceeding anyway...")
        }
        print("")

        let totalSteps = display.hdrEnabled ? 2 : 1
        var currentStep = 0

        // Step 1: Apply gamma compensation
        currentStep += 1
        print("  [\(currentStep)/\(totalSteps)] " + "Applying gamma compensation (\(intensity.rawValue))...".colored(.cyan))

        let gammaSuccess = ColorProfileGenerator.applyGammaCompensation(for: display, intensity: intensity)
        if gammaSuccess {
            print("  \(Emoji.check) " + "Gamma compensation applied!".colored(.green))
        } else {
            print("  \(Emoji.cross) " + "Could not apply gamma compensation".colored(.red))
        }

        // Step 2: Disable HDR (if enabled)
        if display.hdrEnabled {
            currentStep += 1
            print("  [\(currentStep)/\(totalSteps)] " + "Disabling HDR...".colored(.cyan))

            let hdrSuccess = HDRManager.disableHDR(for: display)
            if hdrSuccess {
                print("  \(Emoji.check) " + "HDR disabled".colored(.green))
            } else {
                print("  \(Emoji.warning) " + "Could not auto-disable HDR. Please disable manually in System Settings.".colored(.yellow))
            }
        }

        // Done!
        print("")
        print(String(repeating: "═", count: 56).colored(.green))
        print("\(Emoji.celebrate) " + "Colors should now be vivid!".styled(.bold, .green))
        print("")
        print("   Too bright? Try: " + "'macvivid fix --intensity light'".bold())
        print("   Not enough? Try: " + "'macvivid fix --intensity strong'".bold())
        print("")
    }
}
