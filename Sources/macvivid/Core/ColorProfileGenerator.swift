import Foundation
import CoreGraphics

// MARK: - Color Profile Generator

/// Applies display gamma compensation to fix washed-out colors caused by
/// limited range (16-235) when monitor expects full range (0-255).
///
/// Uses CGSetDisplayTransferByTable — a PUBLIC CoreGraphics API that:
/// ✅ Takes effect IMMEDIATELY (no restart)
/// ✅ No manual System Settings needed
/// ✅ Works on Apple Silicon M1/M2/M3/M4
/// ✅ No sudo required
enum ColorProfileGenerator {

    /// Path for custom color profiles
    static let userProfileDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/ColorSync/Profiles"
    }()

    // MARK: - Public API (Immediate Gamma Fix)

    /// Apply gamma compensation that expands limited range (16-235) to full range (0-255).
    /// This takes effect IMMEDIATELY — no restart, no manual steps.
    /// Intensity levels for gamma compensation
    enum Intensity: String {
        case light = "light"      // Subtle fix, minimal change
        case normal = "normal"    // Default: range expansion + brightness boost
        case strong = "strong"    // Aggressive: high boost for very washed out displays
    }

    /// Apply gamma compensation that expands limited range (16-235) to full range (0-255)
    /// AND boosts brightness + corrects white point to match Mac display.
    static func applyGammaCompensation(for display: DisplayInfo, intensity: Intensity = .normal) -> Bool {
        Logger.debug("Applying gamma compensation for display: \(display.name) (intensity: \(intensity.rawValue))")

        let tableSize: Int = 256
        var redTable = [Float](repeating: 0, count: tableSize)
        var greenTable = [Float](repeating: 0, count: tableSize)
        var blueTable = [Float](repeating: 0, count: tableSize)

        // === ORIGINAL COLOR + DENSITY ===
        //
        // Sesuai strategi:
        // 1. Copy warna original di area terang (White tetap di 255, TIDAK dinaikkan)
        // 2. Tambahkan kepekatan di area gelap (Black dari 16 ditarik ke 0)
        // 3. Tambahkan sedikit kepekatan (gamma) untuk midtones jika diperlukan

        let gamma: Float
        let blackOffsetVal: Float
        let saturation: Float // Untuk mengatasi RGB yang pudar/kurang saturasi
        // Color temperature correction
        let redScale: Float
        let greenScale: Float
        let blueScale: Float

        switch intensity {
        case .light:
            blackOffsetVal = 3.0  // Kegelapan dikurangi lagi agar tidak terlalu berat
            gamma = 1.00
            saturation = 0.15     // Dikurangi jauh dari 0.35 agar warna tidak 'kolot'/berat
            
            // Putih murni 100% (Tidak ada manipulasi software sama sekali)
            redScale = 1.00       
            greenScale = 1.00    
            blueScale = 1.00      
        case .normal:
            blackOffsetVal = 6.0  
            gamma = 1.00
            saturation = 0.25     
            redScale = 0.965       
            greenScale = 0.975
            blueScale = 1.00
        case .strong:
            blackOffsetVal = 9.0 
            gamma = 1.05          
            saturation = 0.35
            redScale = 0.955
            greenScale = 0.965
            blueScale = 1.00
        }

        let blackOffset = blackOffsetVal / 255.0
        let whiteScale = 255.0 / (255.0 - blackOffsetVal)

        for i in 0..<tableSize {
            let input = Float(i) / 255.0

            // Expand limited range to full range
            var expanded = (input - blackOffset) * whiteScale
            expanded = max(0.0, min(1.0, expanded))

            // Smooth S-Curve untuk Saturasi/Kontras (TIDAK menghancurkan abu-abu terang)
            let smooth = expanded * expanded * (3.0 - 2.0 * expanded)
            let contrasted = expanded * (1.0 - saturation) + smooth * saturation
            var output = max(0.0, min(1.0, contrasted))

            // Apply simple uniform gamma
            output = powf(output, gamma)

            // Apply color temperature
            redTable[i]   = min(1.0, output * redScale)
            greenTable[i] = min(1.0, output * greenScale)
            blueTable[i]  = min(1.0, output * blueScale)
        }

        let result = CGSetDisplayTransferByTable(
            display.displayID,
            UInt32(tableSize),
            &redTable,
            &greenTable,
            &blueTable
        )

        if result == .success {
            Logger.debug("Gamma compensation applied successfully!")
            return true
        } else {
            Logger.debug("CGSetDisplayTransferByTable failed with error: \(result.rawValue)")
            return false
        }
    }

    /// Restore default gamma (undo compensation)
    static func restoreDefaultGamma(for display: DisplayInfo) -> Bool {
        Logger.debug("Restoring default gamma for display: \(display.name)")
        CGDisplayRestoreColorSyncSettings()
        return true
    }

    /// Restore gamma for ALL displays
    static func restoreAllGamma() {
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: - ICC Profile (Backup Method)

    /// Also install an ICC profile as a backup method
    /// (User can select this manually if gamma table gets reset)
    static func installFullRangeProfile(for display: DisplayInfo) -> Bool {
        Logger.debug("Generating Full Range RGB color profile for: \(display.name)")

        let profileName = "MacVivid RGB Full Range - \(display.name)"
        let profileData = generateFullRangeICCProfile(name: profileName)

        // Install to user's ColorSync directory (no sudo needed)
        let fm = FileManager.default
        if !fm.fileExists(atPath: userProfileDir) {
            do {
                try fm.createDirectory(atPath: userProfileDir, withIntermediateDirectories: true)
            } catch {
                Logger.error("Failed to create profile directory: \(error)")
                return false
            }
        }

        let profilePath = "\(userProfileDir)/MacVivid_\(display.name.replacingOccurrences(of: " ", with: "_")).icc"

        do {
            try profileData.write(to: URL(fileURLWithPath: profilePath))
            Logger.debug("ICC Profile saved to: \(profilePath)")
            return true
        } catch {
            Logger.error("Failed to save profile: \(error)")
            return false
        }
    }

    /// Remove custom MacVivid color profile
    static func removeProfile(for display: DisplayInfo) -> Bool {
        let profilePath = "\(userProfileDir)/MacVivid_\(display.name.replacingOccurrences(of: " ", with: "_")).icc"
        try? FileManager.default.removeItem(atPath: profilePath)
        return true
    }

    // MARK: - ICC Profile Generation

    private static func generateFullRangeICCProfile(name: String) -> Data {
        var data = Data()

        // === ICC Profile Header (128 bytes) ===
        let profileSize: UInt32 = 0 // placeholder
        data.append(contentsOf: profileSize.bigEndianBytes)
        data.append(contentsOf: [0x41, 0x50, 0x50, 0x4C])     // CMM "APPL"
        data.append(contentsOf: [0x04, 0x40, 0x00, 0x00])     // Version 4.4
        data.append(contentsOf: [0x6D, 0x6E, 0x74, 0x72])     // Class "mntr"
        data.append(contentsOf: [0x52, 0x47, 0x42, 0x20])     // Space "RGB "
        data.append(contentsOf: [0x58, 0x59, 0x5A, 0x20])     // PCS "XYZ "

        // Date/time
        data.append(contentsOf: UInt16(2026).bigEndianBytes)
        for _ in 0..<5 { data.append(contentsOf: UInt16(0).bigEndianBytes) }

        data.append(contentsOf: [0x61, 0x63, 0x73, 0x70])     // "acsp"
        data.append(contentsOf: [0x41, 0x50, 0x50, 0x4C])     // Platform "APPL"
        data.append(contentsOf: [UInt8](repeating: 0, count: 4))
        data.append(contentsOf: [0x41, 0x50, 0x50, 0x4C])     // Manufacturer
        data.append(contentsOf: [UInt8](repeating: 0, count: 12))
        data.append(contentsOf: UInt32(0).bigEndianBytes)       // Intent
        data.append(contentsOf: [0x00, 0x00, 0xF6, 0xD6])     // D50 X
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x00])     // D50 Y
        data.append(contentsOf: [0x00, 0x00, 0xD3, 0x2D])     // D50 Z
        data.append(contentsOf: [0x41, 0x50, 0x50, 0x4C])     // Creator
        data.append(contentsOf: [UInt8](repeating: 0, count: 44))

        // === Tag Table ===
        let tagCount: UInt32 = 9
        data.append(contentsOf: tagCount.bigEndianBytes)

        let tagTableStart = data.count
        let tagTableSize = Int(tagCount) * 12
        data.append(contentsOf: [UInt8](repeating: 0, count: tagTableSize))
        while data.count % 4 != 0 { data.append(0) }

        struct TagEntry {
            let sig: [UInt8]; var offset: UInt32 = 0; var size: UInt32 = 0
        }
        var tags: [TagEntry] = [
            TagEntry(sig: [0x64,0x65,0x73,0x63]), // desc
            TagEntry(sig: [0x77,0x74,0x70,0x74]), // wtpt
            TagEntry(sig: [0x62,0x6B,0x70,0x74]), // bkpt
            TagEntry(sig: [0x72,0x58,0x59,0x5A]), // rXYZ
            TagEntry(sig: [0x67,0x58,0x59,0x5A]), // gXYZ
            TagEntry(sig: [0x62,0x58,0x59,0x5A]), // bXYZ
            TagEntry(sig: [0x72,0x54,0x52,0x43]), // rTRC
            TagEntry(sig: [0x67,0x54,0x52,0x43]), // gTRC
            TagEntry(sig: [0x62,0x54,0x52,0x43]), // bTRC
        ]

        // desc tag
        tags[0].offset = UInt32(data.count)
        var descData = Data([0x64,0x65,0x73,0x63, 0,0,0,0])
        let nameBytes = Array(name.utf8) + [0]
        descData.append(contentsOf: UInt32(nameBytes.count).bigEndianBytes)
        descData.append(contentsOf: nameBytes)
        descData.append(contentsOf: [UInt8](repeating: 0, count: 8))
        descData.append(contentsOf: UInt16(0).bigEndianBytes)
        descData.append(0)
        descData.append(contentsOf: [UInt8](repeating: 0, count: 67))
        data.append(descData)
        tags[0].size = UInt32(descData.count)
        while data.count % 4 != 0 { data.append(0) }

        // XYZ tags helper
        func appendXYZ(_ idx: Int, _ x: Double, _ y: Double, _ z: Double) {
            tags[idx].offset = UInt32(data.count)
            var d = Data([0x58,0x59,0x5A,0x20, 0,0,0,0])
            func s15(_ v: Double) -> [UInt8] {
                let f = Int32(v * 65536.0)
                return [UInt8((f>>24)&0xFF),UInt8((f>>16)&0xFF),UInt8((f>>8)&0xFF),UInt8(f&0xFF)]
            }
            d.append(contentsOf: s15(x)); d.append(contentsOf: s15(y)); d.append(contentsOf: s15(z))
            data.append(d)
            tags[idx].size = UInt32(d.count)
            while data.count % 4 != 0 { data.append(0) }
        }

        appendXYZ(1, 0.9505, 1.0, 1.089)   // wtpt D65
        appendXYZ(2, 0.0, 0.0, 0.0)         // bkpt
        appendXYZ(3, 0.4361, 0.2225, 0.0139) // rXYZ
        appendXYZ(4, 0.3851, 0.7169, 0.0971) // gXYZ
        appendXYZ(5, 0.1431, 0.0606, 0.7142) // bXYZ

        // TRC (shared for R/G/B)
        let trcOffset = UInt32(data.count)
        var trcData = Data([0x63,0x75,0x72,0x76, 0,0,0,0])
        trcData.append(contentsOf: UInt32(256).bigEndianBytes)
        for i in 0..<256 {
            let input = Double(i) / 255.0
            var expanded = (input - 16.0/255.0) * (255.0/219.0)
            expanded = max(0.0, min(1.0, expanded))
            let value = UInt16(max(0, min(65535, expanded * 65535.0)))
            trcData.append(contentsOf: value.bigEndianBytes)
        }
        data.append(trcData)
        let trcSize = UInt32(trcData.count)
        while data.count % 4 != 0 { data.append(0) }

        for i in 6...8 { tags[i].offset = trcOffset; tags[i].size = trcSize }

        // Fill tag table
        var tt = Data()
        for t in tags { tt.append(contentsOf: t.sig); tt.append(contentsOf: t.offset.bigEndianBytes); tt.append(contentsOf: t.size.bigEndianBytes) }
        data.replaceSubrange(tagTableStart..<(tagTableStart + tagTableSize), with: tt)

        // Update size
        let sz = UInt32(data.count).bigEndianBytes
        data.replaceSubrange(0..<4, with: sz)

        return data
    }
}

// MARK: - Numeric Extensions

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self>>24)&0xFF), UInt8((self>>16)&0xFF), UInt8((self>>8)&0xFF), UInt8(self&0xFF)]
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self>>8)&0xFF), UInt8(self&0xFF)]
    }
}
