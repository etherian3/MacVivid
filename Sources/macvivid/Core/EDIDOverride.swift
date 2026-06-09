import Foundation

// MARK: - EDID Override Generator & Installer

/// Generates and installs EDID override files to force RGB Full Range
enum EDIDOverride {

    /// Base path for display overrides
    static let overrideBasePath = "/Library/Displays/Contents/Resources/Overrides"

    // MARK: - Public API

    /// Generate and install EDID override for a display
    /// Works with or without existing EDID data — can generate synthetic EDID
    static func install(for display: DisplayInfo) -> Bool {
        Logger.debug("Installing EDID override for: \(display.name)")

        let patchedData: Data

        if let edidHex = display.edidHex, !edidHex.isEmpty,
           let parsedEDID = EDIDParser.parse(hexString: edidHex) {
            // Patch existing EDID
            Logger.debug("Patching existing EDID data")
            patchedData = EDIDParser.patchForRGBFullRange(data: parsedEDID.rawData)
        } else {
            // Generate synthetic EDID for this monitor
            Logger.debug("No EDID data available, generating synthetic EDID for \(display.resolution.width)x\(display.resolution.height)")
            patchedData = generateSyntheticEDID(
                vendorID: display.vendorID,
                productID: display.productID,
                width: display.resolution.width,
                height: display.resolution.height,
                refreshRate: display.resolution.refreshRate,
                name: display.name
            )
        }

        // Generate the override plist
        let plistData = generateOverridePlist(
            vendorID: display.vendorID,
            productID: display.productID,
            displayName: display.name,
            patchedEDID: patchedData
        )

        guard !plistData.isEmpty else {
            Logger.error("Failed to generate override plist data")
            return false
        }

        // Create the override directory and file
        let vendorHex = String(format: "%x", display.vendorID)
        let productHex = String(format: "%x", display.productID)

        let vendorDir = "\(overrideBasePath)/DisplayVendorID-\(vendorHex)"
        let overrideFile = "\(vendorDir)/DisplayProductID-\(productHex)"

        // Create directory with sudo
        let mkdirResult = ShellRunner.sudoMkdir(vendorDir)
        if !mkdirResult.isSuccess {
            Logger.error("Failed to create override directory: \(mkdirResult.error)")
            return false
        }

        // Write plist to temporary file first, then copy with sudo
        let tempFile = NSTemporaryDirectory() + "macvivid_edid_override.plist"

        do {
            try plistData.write(to: URL(fileURLWithPath: tempFile))
        } catch {
            Logger.error("Failed to write temporary override file: \(error)")
            return false
        }

        // Copy with sudo
        let copyResult = ShellRunner.sudoCopy(from: tempFile, to: overrideFile)

        // Clean up temp file
        try? FileManager.default.removeItem(atPath: tempFile)

        if copyResult.isSuccess {
            Logger.debug("EDID override installed at: \(overrideFile)")
            return true
        } else {
            Logger.error("Failed to install EDID override: \(copyResult.error)")
            return false
        }
    }

    /// Remove EDID override for a display
    static func remove(for display: DisplayInfo) -> Bool {
        let vendorHex = String(format: "%x", display.vendorID)
        let productHex = String(format: "%x", display.productID)

        let overrideFile = "\(overrideBasePath)/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"

        guard FileManager.default.fileExists(atPath: overrideFile) else {
            Logger.debug("No EDID override found to remove")
            return true
        }

        let result = ShellRunner.sudoRemove(overrideFile)
        if result.isSuccess {
            Logger.debug("EDID override removed: \(overrideFile)")

            // Also try to remove the vendor directory if empty
            let vendorDir = "\(overrideBasePath)/DisplayVendorID-\(vendorHex)"
            ShellRunner.runWithSudo("rmdir '\(vendorDir)' 2>/dev/null")

            return true
        } else {
            Logger.error("Failed to remove EDID override: \(result.error)")
            return false
        }
    }

    /// Check if an EDID override exists for a display
    static func exists(for display: DisplayInfo) -> Bool {
        let vendorHex = String(format: "%x", display.vendorID)
        let productHex = String(format: "%x", display.productID)
        let overrideFile = "\(overrideBasePath)/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"
        return FileManager.default.fileExists(atPath: overrideFile)
    }

    // MARK: - Synthetic EDID Generation

    /// Generate a synthetic 128-byte EDID that forces RGB Full Range
    /// Used when the original EDID can't be read (Apple Silicon via USB Hub)
    private static func generateSyntheticEDID(
        vendorID: UInt32,
        productID: UInt32,
        width: Int,
        height: Int,
        refreshRate: Int,
        name: String
    ) -> Data {
        var edid = [UInt8](repeating: 0, count: 128)

        // Header (bytes 0-7)
        edid[0] = 0x00; edid[1] = 0xFF; edid[2] = 0xFF; edid[3] = 0xFF
        edid[4] = 0xFF; edid[5] = 0xFF; edid[6] = 0xFF; edid[7] = 0x00

        // Manufacturer ID (bytes 8-9) - encode from vendor ID
        // VendorID 0x3669 = 13929 decimal
        // We'll encode a generic "MSI" = M(13) S(19) I(9)
        // Compressed: (13 << 10) | (19 << 5) | 9 = 13312 + 608 + 9 = 13929
        let vendorU16 = UInt16(vendorID & 0xFFFF)
        edid[8] = UInt8((vendorU16 >> 8) & 0xFF)
        edid[9] = UInt8(vendorU16 & 0xFF)

        // Product code (bytes 10-11) - little-endian
        edid[10] = UInt8(productID & 0xFF)
        edid[11] = UInt8((productID >> 8) & 0xFF)

        // Serial number (bytes 12-15)
        edid[12] = 0x01; edid[13] = 0x00; edid[14] = 0x00; edid[15] = 0x00

        // Week 1, Year 2024 (bytes 16-17)
        edid[16] = 0x01
        edid[17] = UInt8(2024 - 1990) // 34

        // EDID version 1.4 (bytes 18-19)
        edid[18] = 0x01; edid[19] = 0x04

        // Video input definition (byte 20)
        // Bit 7: Digital input
        // Bits 6-4: Color bit depth (010 = 8 bits)
        // Bits 3-0: Interface (0001 = HDMI)
        edid[20] = 0xA1  // Digital, 8-bit, HDMI-a

        // Max horizontal size in cm (byte 21) - 49cm for ~22" 16:9
        edid[21] = 0x31  // 49

        // Max vertical size in cm (byte 22) - 28cm
        edid[22] = 0x1C  // 28

        // Gamma (byte 23) - 2.20 = (220 - 100) = 120
        edid[23] = 0x78

        // Feature support (byte 24)
        // IMPORTANT: NO YCbCr support flags = forces RGB only
        // Bit 7: DPMS standby
        // Bit 4: NO YCbCr 4:2:2
        // Bit 3: NO YCbCr 4:4:4
        // Bit 2: sRGB
        // Bit 1: Preferred timing in DTD1
        // Bit 0: Continuous frequency
        edid[24] = 0x06  // sRGB + preferred timing, NO YCbCr

        // Chromaticity coordinates (bytes 25-34) - sRGB standard
        edid[25] = 0xEE; edid[26] = 0x91; edid[27] = 0xA3; edid[28] = 0x54
        edid[29] = 0x4C; edid[30] = 0x99; edid[31] = 0x26; edid[32] = 0x0F
        edid[33] = 0x50; edid[34] = 0x54

        // Established timings (bytes 35-37)
        edid[35] = 0x21; edid[36] = 0x08; edid[37] = 0x00

        // Standard timings (bytes 38-53)
        // 1920x1080 @ 60Hz
        edid[38] = UInt8((width / 8) - 31)  // (1920/8)-31 = 209
        edid[39] = 0x00  // 60Hz, 16:9 aspect
        // Fill rest with unused
        for i in 40..<54 {
            edid[i] = 0x01
        }

        // Detailed Timing Descriptor 1 (bytes 54-71): 1920x1080 @ 60Hz
        // Pixel clock: 148.500 MHz = 14850 (in 10kHz units)
        edid[54] = UInt8(14850 & 0xFF)  // 0x12
        edid[55] = UInt8((14850 >> 8) & 0xFF)  // 0x3A

        // Horizontal active: 1920, Horizontal blanking: 280
        edid[56] = UInt8(width & 0xFF)  // 0x80
        edid[57] = UInt8(280 & 0xFF)    // 0x18
        edid[58] = UInt8(((width >> 4) & 0xF0) | ((280 >> 8) & 0x0F))  // 0x71

        // Vertical active: 1080, Vertical blanking: 45
        edid[59] = UInt8(height & 0xFF) // 0x38
        edid[60] = UInt8(45 & 0xFF)     // 0x2D
        edid[61] = UInt8(((height >> 4) & 0xF0) | ((45 >> 8) & 0x0F))  // 0x40

        // Sync: H front porch, H sync pulse, V front porch, V sync pulse
        edid[62] = 88   // H front porch
        edid[63] = 44   // H sync pulse width
        edid[64] = 0x45 // V front porch(4) | V sync(5)
        edid[65] = 0x00

        // Image size
        edid[66] = UInt8(490 & 0xFF)  // H image size mm low
        edid[67] = UInt8(280 & 0xFF)  // V image size mm low
        edid[68] = UInt8(((490 >> 4) & 0xF0) | ((280 >> 8) & 0x0F))

        // Borders
        edid[69] = 0x00; edid[70] = 0x00

        // Flags: Non-interlaced, normal display, digital separate sync
        edid[71] = 0x1E

        // Descriptor 2 (bytes 72-89): Display name
        edid[72] = 0x00; edid[73] = 0x00; edid[74] = 0x00
        edid[75] = 0xFC  // Display name tag
        edid[76] = 0x00  // Reserved
        let nameStr = String(name.prefix(13))
        let nameBytes = Array(nameStr.utf8)
        for i in 0..<13 {
            if i < nameBytes.count {
                edid[77 + i] = nameBytes[i]
            } else if i == nameBytes.count {
                edid[77 + i] = 0x0A  // Line feed = end of name
            } else {
                edid[77 + i] = 0x20  // Padding with spaces
            }
        }

        // Descriptor 3 (bytes 90-107): Display range limits
        edid[90] = 0x00; edid[91] = 0x00; edid[92] = 0x00
        edid[93] = 0xFD  // Range limits tag
        edid[94] = 0x00
        edid[95] = 56   // Min V freq
        edid[96] = 76   // Max V freq
        edid[97] = 30   // Min H freq kHz
        edid[98] = 80   // Max H freq kHz
        edid[99] = 17   // Max pixel clock / 10 MHz (170 MHz)
        edid[100] = 0x00 // No secondary timing formula
        for i in 101..<108 {
            edid[i] = 0x0A
        }

        // Descriptor 4 (bytes 108-125): Dummy/unused
        edid[108] = 0x00; edid[109] = 0x00; edid[110] = 0x00
        edid[111] = 0x10  // Dummy descriptor tag
        edid[112] = 0x00
        for i in 113..<126 {
            edid[i] = 0x0A
        }

        // Extension blocks (byte 126)
        edid[126] = 0x00

        // Checksum (byte 127) - all 128 bytes must sum to 0 mod 256
        var sum: UInt8 = 0
        for i in 0..<127 {
            sum = sum &+ edid[i]
        }
        edid[127] = 0 &- sum

        return Data(edid)
    }

    // MARK: - Plist Generation

    private static func generateOverridePlist(vendorID: UInt32, productID: UInt32, displayName: String, patchedEDID: Data) -> Data {
        // Build the override plist that forces RGB on Apple Silicon
        let plist: [String: Any] = [
            "DisplayProductID": Int(productID),
            "DisplayVendorID": Int(vendorID),
            "DisplayProductName": displayName + " (MacVivid RGB)",
            "IODisplayEDID": patchedEDID,
            // These keys help macOS treat this as a PC monitor, not a TV
            "DisplayIsTV": false,
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            return data
        } catch {
            Logger.error("Failed to serialize override plist: \(error)")
            return Data()
        }
    }
}
