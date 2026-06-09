import Foundation

// MARK: - EDID Parser

/// Parses EDID (Extended Display Identification Data) binary data
/// Reference: VESA EDID Specification
enum EDIDParser {

    /// Parsed EDID result
    struct ParsedEDID {
        let manufacturerCode: String
        let productCode: UInt16
        let serialNumber: UInt32
        let weekOfManufacture: UInt8
        let yearOfManufacture: Int
        let edidVersion: String
        let displayName: String?
        let isDigitalInput: Bool
        let supportsRGB: Bool
        let supportsYCbCr444: Bool
        let supportsYCbCr422: Bool
        let maxHorizontalSize: Int  // cm
        let maxVerticalSize: Int    // cm
        let gamma: Double
        let rawData: Data
    }

    // MARK: - Public API

    /// Parse EDID data from hex string
    static func parse(hexString: String) -> ParsedEDID? {
        guard let data = Data(hexString: hexString) else {
            Logger.debug("EDID: Failed to convert hex string to data")
            return nil
        }
        return parse(data: data)
    }

    /// Parse EDID data from binary Data
    static func parse(data: Data) -> ParsedEDID? {
        guard data.count >= 128 else {
            Logger.debug("EDID: Data too short (\(data.count) bytes, need at least 128)")
            return nil
        }

        // Validate EDID header (bytes 0-7 must be: 00 FF FF FF FF FF FF 00)
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        for i in 0..<8 {
            if data[i] != header[i] {
                Logger.debug("EDID: Invalid header at byte \(i)")
                return nil
            }
        }

        let bytes = [UInt8](data)

        // Manufacturer code (bytes 8-9) - Compressed ASCII
        let manufacturerCode = decodeManufacturerCode(byte1: bytes[8], byte2: bytes[9])

        // Product code (bytes 10-11) - Little-endian
        let productCode = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)

        // Serial number (bytes 12-15) - Little-endian
        let serialNumber = UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24)

        // Week and year of manufacture (bytes 16-17)
        let weekOfManufacture = bytes[16]
        let yearOfManufacture = Int(bytes[17]) + 1990

        // EDID version (bytes 18-19)
        let edidVersion = "\(bytes[18]).\(bytes[19])"

        // Video input definition (byte 20)
        let isDigitalInput = (bytes[20] & 0x80) != 0

        // Feature support (byte 24)
        let supportsYCbCr444 = (bytes[24] & 0x08) != 0
        let supportsYCbCr422 = (bytes[24] & 0x10) != 0
        let supportsRGB = true // RGB is always supported in base EDID

        // Display size (bytes 21-22) in cm
        let maxHorizontalSize = Int(bytes[21])
        let maxVerticalSize = Int(bytes[22])

        // Gamma (byte 23)
        let gamma = Double(bytes[23]) / 100.0 + 1.0

        // Parse descriptor blocks for display name (bytes 54-125, four 18-byte blocks)
        let displayName = parseDisplayName(bytes: bytes)

        return ParsedEDID(
            manufacturerCode: manufacturerCode,
            productCode: productCode,
            serialNumber: serialNumber,
            weekOfManufacture: weekOfManufacture,
            yearOfManufacture: yearOfManufacture,
            edidVersion: edidVersion,
            displayName: displayName,
            isDigitalInput: isDigitalInput,
            supportsRGB: supportsRGB,
            supportsYCbCr444: supportsYCbCr444,
            supportsYCbCr422: supportsYCbCr422,
            maxHorizontalSize: maxHorizontalSize,
            maxVerticalSize: maxVerticalSize,
            gamma: gamma,
            rawData: data
        )
    }

    // MARK: - EDID Patching

    /// Patch EDID data to force RGB Full Range
    /// This modifies the feature support byte to remove YCbCr support flags,
    /// forcing macOS to use RGB.
    static func patchForRGBFullRange(data: Data) -> Data {
        guard data.count >= 128 else { return data }

        var patched = [UInt8](data)

        // Byte 24: Feature Support
        // Bit 3: YCbCr 4:4:4 support → clear it
        // Bit 4: YCbCr 4:2:2 support → clear it
        // This forces macOS to use RGB only
        patched[24] = patched[24] & 0xE7  // Clear bits 3 and 4

        // Ensure digital input flag is set (byte 20, bit 7)
        patched[20] = patched[20] | 0x80

        // Recalculate checksum (byte 127)
        // Checksum: all 128 bytes must sum to 0 (mod 256)
        var sum: UInt8 = 0
        for i in 0..<127 {
            sum = sum &+ patched[i]
        }
        patched[127] = 0 &- sum

        return Data(patched)
    }

    // MARK: - Private Helpers

    /// Decode 3-letter manufacturer code from bytes 8-9
    private static func decodeManufacturerCode(byte1: UInt8, byte2: UInt8) -> String {
        let combined = (UInt16(byte1) << 8) | UInt16(byte2)

        let char1 = Character(UnicodeScalar(((combined >> 10) & 0x1F) + 64)!)
        let char2 = Character(UnicodeScalar(((combined >> 5) & 0x1F) + 64)!)
        let char3 = Character(UnicodeScalar((combined & 0x1F) + 64)!)

        return String([char1, char2, char3])
    }

    /// Parse display name from descriptor blocks
    private static func parseDisplayName(bytes: [UInt8]) -> String? {
        // There are 4 descriptor blocks starting at byte 54, each 18 bytes
        for blockStart in stride(from: 54, to: 126, by: 18) {
            // Check if this is a display name descriptor
            // Bytes 0-2 must be 0x00, byte 3 must be 0xFC
            if bytes[blockStart] == 0 && bytes[blockStart + 1] == 0 &&
               bytes[blockStart + 2] == 0 && bytes[blockStart + 3] == 0xFC {
                // Display name is in bytes 5-17 of the descriptor
                var nameBytes: [UInt8] = []
                for i in (blockStart + 5)..<(blockStart + 18) {
                    if bytes[i] == 0x0A || bytes[i] == 0x00 { break } // Line feed = end of name
                    nameBytes.append(bytes[i])
                }
                if let name = String(bytes: nameBytes, encoding: .ascii) {
                    return name.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}

// MARK: - Data Extension for Hex String

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
