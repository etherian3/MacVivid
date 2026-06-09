import Foundation

// MARK: - ANSI Color & Style Codes for Terminal Output

enum ANSIColor: String {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"
    case italic = "\u{001B}[3m"
    case underline = "\u{001B}[4m"

    // Regular colors
    case black = "\u{001B}[30m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"

    // Bright colors
    case brightRed = "\u{001B}[91m"
    case brightGreen = "\u{001B}[92m"
    case brightYellow = "\u{001B}[93m"
    case brightBlue = "\u{001B}[94m"
    case brightMagenta = "\u{001B}[95m"
    case brightCyan = "\u{001B}[96m"
    case brightWhite = "\u{001B}[97m"

    // Background colors
    case bgRed = "\u{001B}[41m"
    case bgGreen = "\u{001B}[42m"
    case bgYellow = "\u{001B}[43m"
    case bgBlue = "\u{001B}[44m"
    case bgMagenta = "\u{001B}[45m"
    case bgCyan = "\u{001B}[46m"
}

// MARK: - String Extension for Coloring

extension String {
    func colored(_ color: ANSIColor) -> String {
        return "\(color.rawValue)\(self)\(ANSIColor.reset.rawValue)"
    }

    func bold() -> String {
        return "\(ANSIColor.bold.rawValue)\(self)\(ANSIColor.reset.rawValue)"
    }

    func styled(_ styles: ANSIColor...) -> String {
        let prefix = styles.map { $0.rawValue }.joined()
        return "\(prefix)\(self)\(ANSIColor.reset.rawValue)"
    }
}

// MARK: - Emoji Constants

enum Emoji {
    static let monitor = "[*]"
    static let check = "[OK]"
    static let cross = "[!]"
    static let warning = "[!]"
    static let wrench = "[~]"
    static let save = "[S]"
    static let celebrate = "[+]"
    static let info = "[i]"
    static let lightbulb = "[>]"
    static let shield = "[#]"
    static let revert = "[<]"
    static let lock = "[L]"
    static let unlock = "[U]"
    static let search = "[?]"
    static let rocket = "[^]"
    static let paint = "[P]"
    static let link = "[@]"
    static let clock = "[T]"
}

// MARK: - Box Drawing Helpers

enum BoxDraw {
    static func header(_ text: String, width: Int = 56) -> String {
        let topBorder = "╔" + String(repeating: "═", count: width) + "╗"
        let bottomBorder = "╚" + String(repeating: "═", count: width) + "╝"
        let paddedText = centerText(text, width: width)
        let line = "║" + paddedText + "║"
        return [topBorder, line, bottomBorder].joined(separator: "\n")
    }

    static func box(_ lines: [String], width: Int = 56) -> String {
        let innerWidth = width - 2  // Account for "│ " and " │"
        let topBorder = "┌" + String(repeating: "─", count: width) + "┐"
        let bottomBorder = "└" + String(repeating: "─", count: width) + "┘"
        let content = lines.map { line in
            let visible = visibleLength(line)
            let padNeeded = max(0, innerWidth - visible)
            return "│ " + line + String(repeating: " ", count: padNeeded) + " │"
        }
        return ([topBorder] + content + [bottomBorder]).joined(separator: "\n")
    }

    static func separator(width: Int = 56) -> String {
        return "├" + String(repeating: "─", count: width) + "┤"
    }

    /// Calculate the visible terminal width of a string (ignoring ANSI escape codes)
    /// This is critical for box drawing alignment
    static func visibleLength(_ str: String) -> Int {
        // Strip ANSI escape codes using actual ESC character (0x1B)
        let stripped = str.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
        // Count visible width character by character
        // We use index-based scan so we can look ahead for variation selectors
        var width = 0
        var scalars = Array(stripped.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            // Check if next char is U+FE0F (variation selector-16, upgrades symbol to emoji presentation = width 2)
            let nextIsVS16 = (i + 1 < scalars.count) && scalars[i + 1].value == 0xFE0F

            if v == 0xFE0F || v == 0x200D || v == 0x20E3 {
                // Variation selector, ZWJ, combining keycap — zero width, skip
                width += 0
            } else if v >= 0x1F000 && v <= 0x1FAFF {
                // Modern emoji (Emoticons, Symbols, Pictographs)
                width += 2
                if i + 1 < scalars.count && scalars[i + 1].value == 0xFE0F { i += 1 } // consume VS16
            } else if v >= 0x2600 && v <= 0x27BF {
                // Misc Symbols & Dingbats: width depends on VS16
                // With VS16: emoji presentation = 2 cols; without: text = 1 col
                if nextIsVS16 {
                    width += 2
                    i += 1 // consume the VS16
                } else {
                    width += 1
                }
            } else if v >= 0x2300 && v <= 0x23FF {
                // Misc Technical
                width += nextIsVS16 ? 2 : 1
                if nextIsVS16 { i += 1 }
            } else if v >= 0x2B05 && v <= 0x2BFF {
                // Supplemental arrows / misc
                width += nextIsVS16 ? 2 : 1
                if nextIsVS16 { i += 1 }
            } else if v >= 0x2190 && v <= 0x21FF {
                // Arrows
                width += 1
            } else if v >= 0x2500 && v <= 0x25FF {
                // Box drawing characters — always 1 col
                width += 1
            } else if v >= 0x3000 && v <= 0x9FFF {
                // CJK characters — 2 cols
                width += 2
            } else if v > 0xFFFF {
                // Supplementary planes (emoji, etc.)
                width += 2
            } else {
                // ASCII and basic latin — 1 col
                width += 1
            }
            i += 1
        }
        return width
    }

    private static func centerText(_ text: String, width: Int) -> String {
        let textLen = visibleLength(text)
        if textLen >= width {
            return String(text.prefix(width))
        }
        let leftPad = (width - textLen) / 2
        let rightPad = width - textLen - leftPad
        return String(repeating: " ", count: leftPad) + text + String(repeating: " ", count: rightPad)
    }
}
