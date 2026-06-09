import ArgumentParser
import Foundation

// MARK: - Status Command

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the current status of all connected monitors."
    )

    @Flag(name: .shortAndLong, help: "Show verbose debug output.")
    var verbose = false

    @Flag(name: .long, help: "Output in JSON format.")
    var json = false

    mutating func run() throws {
        Logger.setup(verbose: verbose)
        ConfigBackup.ensureDirectories()

        if json {
            printJSON()
            return
        }

        printBanner()
        printDisplayStatus()
    }

    // MARK: - Banner

    private func printBanner() {
        let banner = BoxDraw.header("MacVivid v0.1.0 — Display Color Doctor", width: 54)
        print(banner.colored(.brightCyan))
        print("")
    }

    // MARK: - Display Status

    private func printDisplayStatus() {
        let allDisplays = DisplayDetector.detectAll()
        let externalDisplays = allDisplays.filter { $0.isExternal }
        let builtInDisplays = allDisplays.filter { !$0.isExternal }

        if allDisplays.isEmpty {
            Logger.warning("No displays detected. Make sure your monitor is connected.")
            return
        }

        // Summary
        print("\(Emoji.monitor) " + "Displays Detected: ".bold() + "\(allDisplays.count) total (\(externalDisplays.count) external, \(builtInDisplays.count) built-in)")
        print("")

        // External displays first
        if externalDisplays.isEmpty {
            Logger.warning("No external monitors detected.")
            Logger.info("Make sure your external monitor is connected and powered on.")
            print("")
        } else {
            for display in externalDisplays {
                printDisplayCard(display)
            }
        }

        // Built-in display (abbreviated)
        for display in builtInDisplays {
            printBuiltInDisplay(display)
        }

        // Recommendations
        if !externalDisplays.isEmpty {
            printRecommendations(externalDisplays)
        }
    }

    // MARK: - Display Card

    private func printDisplayCard(_ display: DisplayInfo) {
        let watchdogActive = GammaWatchdog.isRunning()
        let fixStatus = watchdogActive ? "[OK] Active (gamma fix running)" : "[!] Not Active"

        let lines: [String] = [
            "Monitor: \(display.name)".bold(),
            "Connection: \(display.connectionType.rawValue)",
            "Display ID: \(display.displayIDHex)",
            "Vendor: \(display.vendorIDHex)  |  Product: \(display.productIDHex)",
            "Resolution: \(display.resolution)",
            "Color Mode: \(display.colorMode.description)",
            "HDR: \(display.hdrEnabled ? "Enabled [!]" : "Disabled")",
            "MacVivid Fix: \(fixStatus)"
        ]

        let box = BoxDraw.box(lines, width: 56)
        print(box)
        print("")
    }

    // MARK: - Built-in Display

    private func printBuiltInDisplay(_ display: DisplayInfo) {
        print("  " + "\(display.name)".colored(.dim) + " -- \(display.resolution) (built-in, no fix needed)")
        print("")
    }

    // MARK: - Recommendations

    private func printRecommendations(_ displays: [DisplayInfo]) {
        let watchdogActive = GammaWatchdog.isRunning()

        print(String(repeating: "─", count: 56).colored(.dim))

        if watchdogActive {
            print("\(Emoji.check) " + "MacVivid fix is ACTIVE".styled(.bold, .green) + " — colors are being corrected.")
            print("")
            print("\(Emoji.lightbulb) " + "Run ".colored(.cyan) + "'macvivid revert'".bold() + " to undo the fix.".colored(.cyan))
        } else {
            let issueDisplays = displays.filter { $0.hasColorIssue }
            if issueDisplays.isEmpty {
                print("\(Emoji.check) " + "All external monitors are using optimal color settings!".colored(.green))
            } else {
                for display in issueDisplays {
                    print("\(Emoji.warning) " + "Color issue detected on ".colored(.yellow) + display.name.bold())
                    if display.colorMode.encoding != .rgb {
                        print("   Current: \(display.colorMode.encoding.rawValue) → Should be: RGB".colored(.yellow))
                    }
                    if display.colorMode.range != .full {
                        print("   Range: \(display.colorMode.range.rawValue) → Should be: Full Range".colored(.yellow))
                    }
                }
                print("")
                print("\(Emoji.lightbulb) " + "Run ".colored(.cyan) + "'macvivid fix'".bold() + " to fix washed out colors.".colored(.cyan))
            }
        }
        print("")
    }

    // MARK: - JSON Output

    private func printJSON() {
        let displays = DisplayDetector.detectAll()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(displays),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        } else {
            Logger.error("Failed to encode display info to JSON")
        }
    }
}
