import Foundation

// MARK: - Display Information Model

/// Represents information about a connected display
struct DisplayInfo: Codable {
    /// CoreGraphics display ID
    let displayID: UInt32

    /// Human-readable display name
    let name: String

    /// Vendor ID from EDID
    let vendorID: UInt32

    /// Product ID from EDID
    let productID: UInt32

    /// Serial number (if available)
    let serialNumber: UInt32

    /// Connection type (HDMI, DisplayPort, USB-C, etc.)
    let connectionType: ConnectionType

    /// Current resolution
    let resolution: Resolution

    /// Current color mode info
    var colorMode: ColorMode

    /// Whether HDR is enabled
    var hdrEnabled: Bool

    /// Whether this is an external display
    let isExternal: Bool

    /// Whether MacVivid protection is active
    var isProtected: Bool

    /// Raw EDID data (hex string)
    let edidHex: String?

    /// Formatted display ID as hex string
    var displayIDHex: String {
        return String(format: "0x%08X", displayID)
    }

    /// Formatted vendor ID as hex string
    var vendorIDHex: String {
        return String(format: "0x%04X", vendorID)
    }

    /// Formatted product ID as hex string
    var productIDHex: String {
        return String(format: "0x%04X", productID)
    }

    /// Whether this display likely has washed out colors
    var hasColorIssue: Bool {
        return colorMode.encoding != .rgb || colorMode.range != .full
    }
}

// MARK: - Connection Type

enum ConnectionType: String, Codable {
    case hdmi = "HDMI"
    case displayPort = "DisplayPort"
    case usbC = "USB-C"
    case thunderbolt = "Thunderbolt"
    case dvi = "DVI"
    case vga = "VGA"
    case hdmiViaHub = "HDMI (via USB Hub)"
    case builtIn = "Built-in"
    case unknown = "Unknown"

    var emoji: String {
        switch self {
        case .hdmiViaHub: return "🔗"
        case .hdmi: return "📺"
        case .displayPort, .thunderbolt, .usbC: return "🔌"
        case .builtIn: return "💻"
        default: return "🖥️"
        }
    }
}

// MARK: - Resolution

struct Resolution: Codable, CustomStringConvertible {
    let width: Int
    let height: Int
    let refreshRate: Int

    var description: String {
        return "\(width)x\(height) @ \(refreshRate)Hz"
    }
}

// MARK: - Color Mode

struct ColorMode: Codable {
    var encoding: PixelEncoding
    var range: ColorRange
    var bitDepth: Int
    var chromaSubsampling: String?

    var description: String {
        var result = "\(encoding.rawValue) \(range.rawValue)"
        if let chroma = chromaSubsampling, !chroma.isEmpty {
            result += " (\(chroma))"
        }
        result += " \(bitDepth)-bit"
        return result
    }

    var isOptimal: Bool {
        return encoding == .rgb && range == .full
    }

    var statusEmoji: String {
        return isOptimal ? "✅" : "⚠️"
    }
}

// MARK: - Pixel Encoding

enum PixelEncoding: String, Codable {
    case rgb = "RGB"
    case ycbcr444 = "YCbCr 4:4:4"
    case ycbcr422 = "YCbCr 4:2:2"
    case ycbcr420 = "YCbCr 4:2:0"
    case unknown = "Unknown"
}

// MARK: - Color Range

enum ColorRange: String, Codable {
    case full = "Full Range"
    case limited = "Limited Range"
    case unknown = "Unknown"
}

// MARK: - Display Configuration (for backup/restore)

struct DisplayConfiguration: Codable {
    let timestamp: Date
    let displays: [DisplayInfo]
    let plistBackupPath: String?
    let edidOverridePaths: [String]

    var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: timestamp)
    }
}
