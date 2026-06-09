import Foundation
import CoreGraphics
import IOKit

// MARK: - Display Detector

/// Detects and enumerates connected displays using CoreGraphics and IOKit
enum DisplayDetector {

    // MARK: - Public API

    /// Detect all connected displays
    static func detectAll() -> [DisplayInfo] {
        var displays: [DisplayInfo] = []

        // Get active display IDs from CoreGraphics
        let displayIDs = getActiveDisplayIDs()

        Logger.debug("Found \(displayIDs.count) active display(s) via CoreGraphics")

        for displayID in displayIDs {
            if let info = getDisplayInfo(for: displayID) {
                displays.append(info)
            }
        }

        // If no displays found via CoreGraphics, try system_profiler fallback
        if displays.isEmpty {
            Logger.debug("No displays found via CoreGraphics, trying system_profiler fallback...")
            displays = getDisplaysViaSystemProfiler()
        }

        return displays
    }

    /// Detect only external displays
    static func detectExternal() -> [DisplayInfo] {
        return detectAll().filter { $0.isExternal }
    }

    /// Find a specific display by name (partial match)
    static func findDisplay(named name: String) -> DisplayInfo? {
        let displays = detectExternal()
        return displays.first { display in
            display.name.localizedCaseInsensitiveContains(name)
        }
    }

    // MARK: - CoreGraphics Display Detection

    private static func getActiveDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            Logger.debug("CGGetActiveDisplayList returned no displays")
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return []
        }

        return Array(displayIDs.prefix(Int(displayCount)))
    }

    private static func getDisplayInfo(for displayID: CGDirectDisplayID) -> DisplayInfo? {
        let vendorID = CGDisplayVendorNumber(displayID)
        let modelID = CGDisplayModelNumber(displayID)
        let serialNum = CGDisplaySerialNumber(displayID)
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

        // Get display mode info
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            Logger.debug("Could not get display mode for display \(displayID)")
            return nil
        }

        let width = mode.width
        let height = mode.height
        let refreshRate = Int(mode.refreshRate)

        // Get display name and EDID via IOKit
        let ioInfo = getIOKitDisplayInfo(vendorID: vendorID, productID: modelID)
        let displayName = ioInfo.name ?? getDisplayName(displayID: displayID, vendorID: vendorID, modelID: modelID, isBuiltIn: isBuiltIn)

        // Determine connection type
        let connectionType = determineConnectionType(displayID: displayID, isBuiltIn: isBuiltIn, ioConnectionType: ioInfo.connectionType)

        // Get color mode info
        let colorMode = getColorMode(displayID: displayID)

        // Check HDR status
        let hdrEnabled = checkHDRStatus(displayID: displayID)

        // Check protection status
        let isProtected = checkProtectionStatus(vendorID: vendorID, productID: modelID)

        return DisplayInfo(
            displayID: displayID,
            name: displayName,
            vendorID: vendorID,
            productID: modelID,
            serialNumber: serialNum,
            connectionType: connectionType,
            resolution: Resolution(width: width, height: height, refreshRate: refreshRate > 0 ? refreshRate : 60),
            colorMode: colorMode,
            hdrEnabled: hdrEnabled,
            isExternal: !isBuiltIn,
            isProtected: isProtected,
            edidHex: ioInfo.edidHex
        )
    }

    // MARK: - IOKit Display Info

    private struct IOKitDisplayInfo {
        let name: String?
        let edidHex: String?
        let connectionType: String?
    }

    private static func getIOKitDisplayInfo(vendorID: UInt32, productID: UInt32) -> IOKitDisplayInfo {
        var name: String? = nil
        var edidHex: String? = nil
        var connectionType: String? = nil

        // Try multiple IOKit class names (Apple Silicon may use different classes)
        let classNames = ["IODisplayConnect", "AppleDisplay"]

        for className in classNames {
            let matching = IOServiceMatching(className)
            var iterator: io_iterator_t = 0

            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                Logger.debug("IOKit: Failed to get matching services for \(className)")
                continue
            }
            defer { IOObjectRelease(iterator) }

            var service: io_object_t = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                guard let infoDict = IODisplayCreateInfoDictionary(service, UInt32(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] else {
                    continue
                }

                // Check if this matches our display
                guard let ioVendor = infoDict["DisplayVendorID"] as? UInt32,
                      let ioProduct = infoDict["DisplayProductID"] as? UInt32,
                      ioVendor == vendorID, ioProduct == productID else {
                    continue
                }

                // Extract display name
                if let nameDict = infoDict["DisplayProductName"] as? [String: String] {
                    name = nameDict.values.first
                }

                // Extract EDID data
                if let edidData = infoDict["IODisplayEDID"] as? Data {
                    edidHex = edidData.map { String(format: "%02x", $0) }.joined()
                }

                // Try to get connection type from IOKit registry
                connectionType = getConnectionTypeFromIOKit(service: service)

                break
            }

            // If we found info, stop searching
            if name != nil || edidHex != nil {
                break
            }
        }

        // Fallback: try ioreg command line for EDID if not found via API
        if edidHex == nil {
            Logger.debug("IOKit API didn't return EDID, trying ioreg command fallback...")
            let result = ShellRunner.run("ioreg -r -d1 -c IODisplayConnect -w0 2>/dev/null | grep IODisplayEDID | head -1 | sed 's/.*<//;s/>//'")
            if result.isSuccess && !result.output.isEmpty && result.output.count >= 256 {
                edidHex = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                Logger.debug("Got EDID via ioreg command: \(edidHex?.prefix(32) ?? "nil")...")
            }
        }

        return IOKitDisplayInfo(name: name, edidHex: edidHex, connectionType: connectionType)
    }

    private static func getConnectionTypeFromIOKit(service: io_object_t) -> String? {
        // Walk up the IOKit tree to find connection info
        var parent: io_object_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }

            // Check for class name hints
            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(parent, &className)
            let classStr = String(cString: className)

            if classStr.contains("HDMI") { return "HDMI" }
            if classStr.contains("DP") || classStr.contains("DisplayPort") { return "DisplayPort" }
            if classStr.contains("Thunderbolt") { return "Thunderbolt" }
        }
        return nil
    }

    // MARK: - Display Name

    private static func getDisplayName(displayID: CGDirectDisplayID, vendorID: UInt32, modelID: UInt32, isBuiltIn: Bool) -> String {
        if isBuiltIn {
            return "Built-in Display"
        }

        // Try system_profiler for display name
        if let name = getDisplayNameFromSystemProfiler(vendorID: vendorID) {
            return name
        }

        return "External Display (Vendor: \(String(format: "0x%04X", vendorID)))"
    }

    private static func getDisplayNameFromSystemProfiler(vendorID: UInt32) -> String? {
        let result = ShellRunner.run("system_profiler SPDisplaysDataType 2>/dev/null")
        guard result.isSuccess else { return nil }

        let lines = result.output.components(separatedBy: "\n")
        // Look for display names in the output
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Display names are usually at a specific indentation level
            if trimmed.hasSuffix(":") && !trimmed.contains("Display") && !trimmed.contains("GPU") &&
               !trimmed.contains("Chipset") && !trimmed.contains("Type") && !trimmed.contains("VRAM") &&
               !trimmed.contains("Vendor") && !trimmed.contains("Device") && !trimmed.contains("Revision") &&
               !trimmed.contains("Metal") && !trimmed.contains("Total") {
                // Check if this looks like a monitor name
                let name = String(trimmed.dropLast()) // Remove the colon
                if !name.isEmpty && name.count > 2 {
                    // Verify it's near other display properties
                    if index + 1 < lines.count {
                        let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                        if nextLine.contains("Resolution") || nextLine.contains("Display Type") || nextLine.contains("UI Looks") {
                            return name
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Connection Type

    private static func determineConnectionType(displayID: CGDirectDisplayID, isBuiltIn: Bool, ioConnectionType: String?) -> ConnectionType {
        if isBuiltIn {
            return .builtIn
        }

        // Check IOKit-detected connection type
        if let ioType = ioConnectionType {
            if ioType.contains("HDMI") { return .hdmi }
            if ioType.contains("DisplayPort") || ioType.contains("DP") { return .displayPort }
            if ioType.contains("Thunderbolt") { return .thunderbolt }
        }

        // Try ioreg for connection details (targeted query, not full dump)
        let result = ShellRunner.run("ioreg -r -d2 -c IODisplayConnect -w0 2>/dev/null | grep -i 'connection-type\\|connector-type' | head -5")
        if result.isSuccess && !result.output.isEmpty {
            let output = result.output.lowercased()
            if output.contains("hdmi") { return .hdmi }
            if output.contains("dp") || output.contains("displayport") { return .displayPort }
            if output.contains("thunderbolt") { return .thunderbolt }
            if output.contains("usb") { return .hdmiViaHub }
        }

        // Check if connected via USB hub by looking at parent classes
        let usbCheck = ShellRunner.run("ioreg -r -d3 -c IODisplayConnect -w0 2>/dev/null | grep -i 'usb\\|hub' | head -3")
        if usbCheck.isSuccess && !usbCheck.output.isEmpty {
            return .hdmiViaHub
        }

        return .hdmi // Default assumption for external monitors
    }

    // MARK: - Color Mode Detection

    private static func getColorMode(displayID: CGDirectDisplayID) -> ColorMode {
        // Try to read from windowserver plist
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistDir = "\(home)/Library/Preferences/ByHost"

        let result = ShellRunner.run("ls \(plistDir)/com.apple.windowserver.*.plist 2>/dev/null | head -1")
        if result.isSuccess, !result.output.isEmpty {
            let plistPath = result.output
            Logger.debug("Reading windowserver plist: \(plistPath)")

            // Convert to XML and read
            let xmlResult = ShellRunner.run("plutil -convert xml1 -o - '\(plistPath)' 2>/dev/null")
            if xmlResult.isSuccess {
                let content = xmlResult.output

                // Look for pixel encoding info
                if content.contains("ITUR_709") || content.contains("YCbCr") || content.contains("ycbcr") {
                    let encoding: PixelEncoding = content.contains("422") ? .ycbcr422 :
                                                  content.contains("420") ? .ycbcr420 :
                                                  content.contains("444") ? .ycbcr444 : .ycbcr422

                    let range: ColorRange = content.contains("limited") || content.contains("Limited") ? .limited : .full

                    return ColorMode(encoding: encoding, range: range, bitDepth: 8, chromaSubsampling: nil)
                }

                if content.contains("RGB") || content.contains("rgb") {
                    let range: ColorRange = content.contains("Full") || content.contains("full") ? .full : .limited
                    return ColorMode(encoding: .rgb, range: range, bitDepth: 8, chromaSubsampling: nil)
                }
            }
        }

        // Try ioreg for additional info (targeted query)
        let ioregResult = ShellRunner.run("ioreg -r -d2 -c IODisplayConnect -w0 2>/dev/null | grep -i 'pixel.encoding\\|PixelEncoding\\|color.mode' | head -3")
        if ioregResult.isSuccess && !ioregResult.output.isEmpty {
            let output = ioregResult.output.lowercased()
            if output.contains("ycbcr") || output.contains("yuv") {
                return ColorMode(encoding: .ycbcr422, range: .limited, bitDepth: 8, chromaSubsampling: "4:2:2")
            }
            if output.contains("rgb") {
                return ColorMode(encoding: .rgb, range: .full, bitDepth: 8, chromaSubsampling: nil)
            }
        }

        // Default: try to detect from system_profiler
        let spResult = ShellRunner.run("system_profiler SPDisplaysDataType 2>/dev/null | grep -i 'depth\\|color\\|pixel'")
        if spResult.isSuccess {
            let output = spResult.output.lowercased()
            let bitDepth = output.contains("30") ? 10 : 8
            // If we can't determine encoding, report as unknown
            return ColorMode(encoding: .unknown, range: .unknown, bitDepth: bitDepth, chromaSubsampling: nil)
        }

        return ColorMode(encoding: .unknown, range: .unknown, bitDepth: 8, chromaSubsampling: nil)
    }

    // MARK: - HDR Detection

    private static func checkHDRStatus(displayID: CGDirectDisplayID) -> Bool {
        // Check via system_profiler
        let result = ShellRunner.run("system_profiler SPDisplaysDataType 2>/dev/null | grep -i 'HDR'")
        if result.isSuccess {
            let output = result.output.lowercased()
            if output.contains("yes") || output.contains("enabled") || output.contains("supported") {
                return true
            }
        }

        // Check via ioreg (targeted query)
        let ioregResult = ShellRunner.run("ioreg -r -d2 -c IODisplayConnect -w0 2>/dev/null | grep -i 'HDR\\|hdr-supported' | head -3")
        if ioregResult.isSuccess && !ioregResult.output.isEmpty {
            return ioregResult.output.lowercased().contains("yes") || ioregResult.output.contains("= 1")
        }

        return false
    }

    // MARK: - Protection Status

    private static func checkProtectionStatus(vendorID: UInt32, productID: UInt32) -> Bool {
        let vendorHex = String(format: "%x", vendorID)
        let productHex = String(format: "%x", productID)
        let overridePath = "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"

        return FileManager.default.fileExists(atPath: overridePath)
    }

    // MARK: - System Profiler Fallback

    private static func getDisplaysViaSystemProfiler() -> [DisplayInfo] {
        var displays: [DisplayInfo] = []

        let result = ShellRunner.run("system_profiler SPDisplaysDataType -json 2>/dev/null")
        guard result.isSuccess, let data = result.output.data(using: .utf8) else {
            return displays
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let gpuList = json["SPDisplaysDataType"] as? [[String: Any]] {
                for gpu in gpuList {
                    if let ndrvs = gpu["spdisplays_ndrvs"] as? [[String: Any]] {
                        for display in ndrvs {
                            let name = display["_name"] as? String ?? "Unknown Display"
                            let isBuiltIn = (display["spdisplays_builtin"] as? String) == "spdisplays_yes"

                            if !isBuiltIn {
                                // Parse resolution
                                let resStr = display["_spdisplays_resolution"] as? String ?? "1920 x 1080"
                                let parts = resStr.components(separatedBy: CharacterSet(charactersIn: "x×@")).map { $0.trimmingCharacters(in: .whitespaces) }
                                let width = Int(parts[safe: 0] ?? "1920") ?? 1920
                                let height = Int(parts[safe: 1] ?? "1080") ?? 1080
                                let hz = Int(parts[safe: 2]?.replacingOccurrences(of: "Hz", with: "").trimmingCharacters(in: .whitespaces) ?? "60") ?? 60

                                let displayInfo = DisplayInfo(
                                    displayID: 0,
                                    name: name,
                                    vendorID: 0,
                                    productID: 0,
                                    serialNumber: 0,
                                    connectionType: .unknown,
                                    resolution: Resolution(width: width, height: height, refreshRate: hz),
                                    colorMode: ColorMode(encoding: .unknown, range: .unknown, bitDepth: 8, chromaSubsampling: nil),
                                    hdrEnabled: false,
                                    isExternal: true,
                                    isProtected: false,
                                    edidHex: nil
                                )
                                displays.append(displayInfo)
                            }
                        }
                    }
                }
            }
        } catch {
            Logger.debug("Failed to parse system_profiler JSON: \(error)")
        }

        return displays
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
