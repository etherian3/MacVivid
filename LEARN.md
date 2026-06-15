# MacVivid — Codebase Deep Dive

This document explains how MacVivid works internally. It is intended for contributors and developers who want to understand the architecture, the macOS APIs involved, and why certain design decisions were made.

---

## Table of Contents

- [The Core Problem](#the-core-problem)
- [Architecture Overview](#architecture-overview)
- [Module Breakdown](#module-breakdown)
  - [Commands Layer](#commands-layer)
  - [Core Layer](#core-layer)
  - [Utilities Layer](#utilities-layer)
- [How the Fix Works](#how-the-fix-works)
  - [Step 1: Display Detection](#step-1-display-detection)
  - [Step 2: Gamma Compensation](#step-2-gamma-compensation)
  - [Step 3: ICC Color Profile](#step-3-icc-color-profile)
  - [Step 4: EDID Override](#step-4-edid-override)
  - [Step 5: WindowServer Plist](#step-5-windowserver-plist)
- [The Watchdog System](#the-watchdog-system)
- [Intensity Levels Explained](#intensity-levels-explained)
- [Key macOS APIs Used](#key-macos-apis-used)
- [File System Layout](#file-system-layout)
- [Data Flow Diagram](#data-flow-diagram)
- [Known Limitations](#known-limitations)
- [Where to Start If You Want to Contribute](#where-to-start-if-you-want-to-contribute)

---

## The Core Problem

When macOS connects to an external monitor — especially over HDMI through a USB hub — it sometimes misidentifies the display as a TV. As a result, macOS sends video using **YCbCr Limited Range** (signal values 16–235) instead of **RGB Full Range** (0–255).

The monitor, expecting the full 0–255 range, stretches the 16–235 signal to fill its panel. The result is:

- Blacks become muddy gray (16 instead of 0)
- Whites look slightly blown out
- All colors appear washed out and desaturated
- Text looks blurry (sub-pixel rendering is off)

MacVivid corrects this in software by applying an inverse transformation — a gamma compensation table — that pre-adjusts the signal so the output looks correct despite the limited range.

---

## Architecture Overview

MacVivid is a Swift Package Manager (SPM) CLI tool. It uses [swift-argument-parser](https://github.com/apple/swift-argument-parser) for CLI parsing.

```
Sources/macvivid/
├── MacVivid.swift          Entry point, registers subcommands
├── Commands/               CLI interface layer
│   ├── FixCommand.swift    macvivid fix
│   ├── StatusCommand.swift macvivid status
│   ├── RevertCommand.swift macvivid revert
│   ├── ProtectCommand.swift     macvivid protect
│   └── UnprotectCommand.swift   macvivid unprotect
├── Core/                   Business logic
│   ├── DisplayDetector.swift    Enumerate connected displays
│   ├── DisplayInfo.swift        Data model for a display
│   ├── ColorFixer.swift         Orchestrates all fix methods
│   ├── ColorProfileGenerator.swift  Gamma table + ICC profile
│   ├── GammaWatchdog.swift      Background daemon
│   ├── ConfigBackup.swift       Backup and restore
│   ├── EDIDOverride.swift       EDID file injection
│   ├── EDIDParser.swift         Parse raw EDID bytes
│   └── HDRManager.swift         HDR detection and disable
└── Utilities/
    ├── Logger.swift         Colored terminal output + file logging
    ├── ANSIColors.swift     Terminal color/style helpers
    └── ShellRunner.swift    Run shell commands and capture output
```

---

## Module Breakdown

### Commands Layer

Each file in `Commands/` maps to one CLI subcommand. They are thin — they parse user input, call into `Core/`, and print results. They do not contain business logic.

| File | Subcommand | Responsibility |
|---|---|---|
| `FixCommand.swift` | `macvivid fix` | Detects monitors, calls `ColorProfileGenerator`, starts watchdog |
| `StatusCommand.swift` | `macvivid status` | Calls `DisplayDetector`, prints color mode and HDR status |
| `RevertCommand.swift` | `macvivid revert` | Calls `ConfigBackup` and `ColorProfileGenerator.restoreAllGamma()` |
| `ProtectCommand.swift` | `macvivid protect` | Calls `GammaWatchdog.start()` |
| `UnprotectCommand.swift` | `macvivid unprotect` | Calls `GammaWatchdog.stop()` |

All commands use `@Option`, `@Flag`, and `@Argument` decorators from swift-argument-parser. The main entry point in `MacVivid.swift` registers these as subcommands.

---

### Core Layer

This is where everything meaningful happens.

#### `DisplayDetector.swift`

Responsible for finding all connected displays and building `DisplayInfo` structs.

Detection strategy (in order):
1. `CGGetActiveDisplayList` — get display IDs from CoreGraphics
2. `IODisplayCreateInfoDictionary` via IOKit — get monitor name, EDID data, connection type
3. `ioreg` shell command — fallback for EDID if IOKit API returns nothing
4. `system_profiler SPDisplaysDataType` — fallback if CoreGraphics returns nothing

**Why multiple fallbacks?** Apple Silicon (M1/M2/M3/M4) changed the internal IOKit class names. What worked on Intel (`IODisplayConnect`) sometimes does not work on M-series chips. The fallback chain ensures compatibility.

Color mode detection reads the WindowServer plist (`~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist`) to check if the pixel encoding is YCbCr or RGB.

---

#### `DisplayInfo.swift`

Plain data model. Holds everything known about a connected display:

- `displayID` — CoreGraphics display identifier (`CGDirectDisplayID`)
- `vendorID` / `productID` — hardware identifiers from EDID
- `connectionType` — HDMI, DisplayPort, Thunderbolt, USB hub, etc.
- `colorMode` — pixel encoding (RGB/YCbCr) and range (Full/Limited)
- `resolution` — width, height, refresh rate
- `hdrEnabled`, `isExternal`, `isProtected`
- `edidHex` — raw EDID bytes as hex string

---

#### `ColorFixer.swift`

Orchestrates all four fix methods in sequence. A successful result from any one method counts as overall success.

| Method | API / Mechanism | Effect timing |
|---|---|---|
| Gamma compensation | `CGSetDisplayTransferByTable` | Immediate |
| ICC color profile | Write `.icc` file to ColorSync | Manual (user selects) |
| EDID override | Write plist to `/Library/Displays/...` | After reboot |
| WindowServer plist | Edit `com.apple.windowserver.displays.*.plist` | After restart |

Method 1 (gamma) is the only one that takes effect instantly without any restart. It is the primary fix. The others are backup methods that provide persistence.

---

#### `ColorProfileGenerator.swift`

Contains two main responsibilities:

**1. Gamma Compensation (`applyGammaCompensation`)**

This is the heart of MacVivid. It builds a 256-entry lookup table for each color channel (R, G, B) and passes it to CoreGraphics via `CGSetDisplayTransferByTable`.

The table does three things:

1. **Black level correction** — shifts the input floor up from 0 to `blackOffset` (representing the 16/255 bottom of limited range), then rescales the entire range so that input 16 maps to output 0 and input 235 maps to output 255.

2. **S-Curve contrast** — applies a smooth sigmoid curve (`x² × (3 - 2x)`) to add perceived contrast without crushing highlights or losing shadow detail. The `saturation` parameter controls how much of the S-curve is blended in.

3. **Color temperature correction** — slight per-channel scaling (`redScale`, `greenScale`, `blueScale`) to remove the warm/yellow tint that often accompanies the limited range problem.

**2. ICC Profile Generation (`installFullRangeProfile`)**

Generates a minimal but valid ICC v4 profile from scratch (no external libraries). The profile encodes the same limited-to-full-range expansion as a tone reproduction curve (TRC). Users can manually select this in System Settings > Displays > Color Profile as a fallback if the gamma table gets reset.

---

#### `GammaWatchdog.swift`

macOS periodically resets gamma tables (for example, when waking from sleep or reconnecting a monitor). The watchdog prevents this by re-applying the fix every 2 seconds.

Architecture:
- The main process launches a **second instance of itself** with `macvivid fix --watch` as a background process (detached from the terminal)
- The background process runs `GammaWatchdog.runWatchLoop()` — a `while true` loop that sleeps 2 seconds and re-applies gamma
- A PID file at `~/.macvivid/watchdog.pid` tracks the background process
- A config file at `~/.macvivid/watchdog.json` passes display info (displayID, resolution, intensity) to the background process
- On `SIGTERM` or `SIGINT`, the watchdog restores the original gamma via `CGDisplayRestoreColorSyncSettings()` before exiting

Stopping the watchdog: `GammaWatchdog.stop()` reads the PID file and sends `SIGTERM`.

---

#### `ConfigBackup.swift`

Manages timestamped backups of the WindowServer plist before any changes are applied. Backups are stored in `~/.macvivid/backups/`. The `revert` command can restore any specific backup by timestamp.

---

#### `EDIDOverride.swift` and `EDIDParser.swift`

Generates an EDID override plist at `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-{vendor}/DisplayProductID-{product}`. This tells macOS to treat the monitor as an RGB display.

`EDIDParser.swift` reads raw EDID hex data and extracts monitor metadata (manufacturer, model, supported resolutions). This data is used to construct the override plist accurately.

Note: writing to `/Library/Displays/` requires `sudo`. The fix will attempt this but may fail gracefully if not run with sufficient privileges.

---

#### `HDRManager.swift`

Detects and optionally disables HDR on the target display. HDR can interfere with the gamma compensation because macOS uses a different color pipeline for HDR content. Disabling it ensures the gamma table applies correctly.

---

### Utilities Layer

#### `Logger.swift`

Handles all terminal output and optional file logging to `~/.macvivid/logs/`. Log levels: `debug`, `info`, `success`, `warning`, `error`. Debug output is hidden unless `--verbose` is passed.

#### `ANSIColors.swift`

Extension methods on `String` for terminal color and style formatting. Example: `"text".colored(.green)`, `"text".styled(.bold, .brightCyan)`. Used throughout `Commands/` for readable CLI output.

#### `ShellRunner.swift`

A thin wrapper around `Process` that runs a shell command and returns its stdout, stderr, and exit code as a struct. Used by `DisplayDetector`, `ColorFixer`, and `EDIDOverride` to call `ioreg`, `system_profiler`, `plutil`, etc.

---

## How the Fix Works

### Step 1: Display Detection

```
macvivid fix
    └── DisplayDetector.detectExternal()
            ├── CGGetActiveDisplayList()       — get display IDs
            ├── IODisplayCreateInfoDictionary() — get name, EDID
            ├── ioreg (fallback)               — get EDID if IOKit fails
            └── system_profiler (fallback)     — get display list if CoreGraphics fails
```

### Step 2: Gamma Compensation

```
ColorProfileGenerator.applyGammaCompensation(display, intensity)
    ├── Build 256-entry R/G/B lookup tables
    │       ├── Black level shift  (limited range floor correction)
    │       ├── S-Curve contrast   (saturation boost)
    │       └── Color temperature  (per-channel scaling)
    └── CGSetDisplayTransferByTable(displayID, 256, &red, &green, &blue)
             -- Takes effect immediately, no restart needed
```

### Step 3: ICC Color Profile

```
ColorProfileGenerator.installFullRangeProfile(display)
    ├── Generate ICC v4 binary data from scratch
    │       ├── Header (128 bytes)
    │       ├── Tag table (9 tags)
    │       ├── wtpt (white point D65)
    │       ├── rXYZ/gXYZ/bXYZ (sRGB primaries)
    │       └── rTRC/gTRC/bTRC (limited-to-full TRC curve)
    └── Write to ~/Library/ColorSync/Profiles/MacVivid_{name}.icc
```

### Step 4: EDID Override

```
EDIDOverride.install(display)
    ├── Parse existing EDID hex (EDIDParser)
    ├── Build override plist with PixelEncoding = RGB, Range = Full
    └── Write to /Library/Displays/Contents/Resources/Overrides/
              DisplayVendorID-{vendor}/DisplayProductID-{product}
              (requires sudo, persistent after reboot)
```

### Step 5: WindowServer Plist

```
ColorFixer.modifyWindowServerPlist(display)
    ├── Locate com.apple.windowserver.displays.*.plist
    ├── Convert to XML (plutil)
    ├── Traverse DisplaySets > Configs > DisplayConfig
    ├── Add LinkDescription = { PixelEncoding: 0, Range: 0 }
    └── Write back (persistent until next macOS update or reset)
```

---

## The Watchdog System

```
macvivid fix
    └── GammaWatchdog.start(displays, intensity)
            ├── Save display config to ~/.macvivid/watchdog.json
            ├── Launch:  macvivid fix --watch  (background process)
            └── Save PID to ~/.macvivid/watchdog.pid

Background process (macvivid fix --watch):
    └── GammaWatchdog.runWatchLoop()
            ├── Load config from watchdog.json
            ├── Save own PID to watchdog.pid
            ├── Register SIGTERM / SIGINT handlers
            └── Loop every 2 seconds:
                    ├── Check if watchdog.pid still exists
                    └── Re-apply gamma for each display

macvivid unprotect (or macvivid revert):
    └── GammaWatchdog.stop()
            ├── Read PID from watchdog.pid
            └── kill(pid, SIGTERM)
                    └── Watchdog: CGDisplayRestoreColorSyncSettings() -> exit
```

---

## Intensity Levels Explained

The three intensity levels differ in three parameters:

| Parameter | light | normal | strong |
|---|---|---|---|
| `blackOffsetVal` | 3.0 / 255 | 6.0 / 255 | 9.0 / 255 |
| `saturation` (S-curve blend) | 0.15 | 0.25 | 0.35 |
| `gamma` (power curve) | 1.00 | 1.00 | 1.05 |
| `redScale` | 1.00 | 0.965 | 0.955 |
| `greenScale` | 1.00 | 0.975 | 0.965 |
| `blueScale` | 1.00 | 1.00 | 1.00 |

`blackOffsetVal` controls how aggressively the black floor is lifted. A value of 6.0 means input value 6/255 maps to output 0 — expanding the visible range.

`saturation` controls how much S-curve shaping is blended in on top of the linear expansion. Higher values = more "pop" and contrast.

The color temperature scales (`redScale`, `greenScale`) are slightly below 1.0 in normal/strong modes. This adds a subtle cool tint that counteracts the warm cast common on monitors using limited-range YCbCr.

---

## Key macOS APIs Used

| API | Framework | Purpose |
|---|---|---|
| `CGGetActiveDisplayList` | CoreGraphics | Enumerate active display IDs |
| `CGDisplayCopyDisplayMode` | CoreGraphics | Get resolution and refresh rate |
| `CGDisplayIsBuiltin` | CoreGraphics | Distinguish built-in from external |
| `CGSetDisplayTransferByTable` | CoreGraphics | Apply gamma lookup table (the fix) |
| `CGDisplayRestoreColorSyncSettings` | CoreGraphics | Reset gamma to system defaults |
| `IODisplayCreateInfoDictionary` | IOKit | Get display name, EDID, vendor/product IDs |
| `IOServiceGetMatchingServices` | IOKit | Iterate IOKit service tree |
| `IORegistryEntryGetParentEntry` | IOKit | Walk IOKit registry tree |
| `PropertyListSerialization` | Foundation | Read/write WindowServer plist |

External tools called via `ShellRunner`:

| Tool | Purpose |
|---|---|
| `ioreg` | Fallback display enumeration and EDID extraction |
| `system_profiler` | Fallback display info and HDR status |
| `plutil` | Convert WindowServer plist between XML and binary format |
| `defaults` | Write CoreDisplay preferences |

---

## File System Layout

```
~/.macvivid/
├── watchdog.pid           PID of the running background watchdog
├── watchdog.json          Display config passed to watchdog process
├── backups/               Timestamped WindowServer plist backups
│   └── 2026-06-06_225600/
│       └── com.apple.windowserver.displays.*.plist
└── logs/
    └── macvivid.log       Debug log (written when --verbose is used)

~/Library/ColorSync/Profiles/
└── MacVivid_{MonitorName}.icc   Custom ICC profile (backup fix method)

/Library/Displays/Contents/Resources/Overrides/
└── DisplayVendorID-{hex}/
    └── DisplayProductID-{hex}   EDID override plist (persistent fix, needs sudo)
```

---

## Data Flow Diagram

```
User runs: macvivid fix

           ┌──────────────┐
           │  FixCommand  │
           └──────┬───────┘
                  │
          detectExternal()
                  │
           ┌──────▼───────────────────────────┐
           │         DisplayDetector           │
           │  CGGetActiveDisplayList           │
           │  IODisplayCreateInfoDictionary    │
           │  ioreg (fallback)                 │
           │  system_profiler (fallback)       │
           └──────┬───────────────────────────┘
                  │ [DisplayInfo]
           ┌──────▼───────────────────────────┐
           │          ColorFixer              │
           │  Method 1: applyGammaCompensation│ ──► CGSetDisplayTransferByTable (instant)
           │  Method 2: installFullRangeProfile│ ──► ~/.../ColorSync/Profiles/*.icc
           │  Method 3: EDIDOverride.install  │ ──► /Library/Displays/.../plist (reboot)
           │  Method 4: modifyWindowServerPlist│ ──► ~/Library/Preferences/ByHost/*.plist
           └──────┬───────────────────────────┘
                  │
           ┌──────▼───────────────────────────┐
           │         GammaWatchdog            │
           │  Launches: macvivid fix --watch  │
           │  Loop every 2s: re-apply gamma   │
           └──────────────────────────────────┘
```

---

## Known Limitations

- **Gamma table resets on wake** — This is why the watchdog exists. macOS calls `CGDisplayRestoreColorSyncSettings()` internally when the system wakes from sleep or a monitor reconnects. The watchdog re-applies within 2 seconds.

- **EDID override requires sudo** — Writing to `/Library/Displays/` needs root access. The tool attempts it but proceeds without it if not available.

- **Color mode detection is best-effort** — macOS does not expose a direct public API to query the current pixel encoding. MacVivid reads the WindowServer plist to infer it, which may report "unknown" on some configurations.

- **HDR interference** — If HDR is enabled on the monitor, the gamma pipeline is different. MacVivid will attempt to disable HDR, but this may not work on all displays or macOS versions.

- **Intel vs Apple Silicon** — IOKit class names differ between architectures. The fallback chain in `DisplayDetector` handles this, but edge cases may exist on unusual hardware.

---

## Where to Start If You Want to Contribute

| Goal | File to look at first |
|---|---|
| Fix a display detection bug | `DisplayDetector.swift` |
| Adjust or add an intensity level | `ColorProfileGenerator.swift` — `Intensity` enum and `applyGammaCompensation` |
| Change how the watchdog works | `GammaWatchdog.swift` |
| Add a new CLI flag or subcommand | `Commands/FixCommand.swift` or add a new file in `Commands/` |
| Improve the backup/restore system | `ConfigBackup.swift` and `RevertCommand.swift` |
| Fix the EDID override method | `EDIDOverride.swift` and `EDIDParser.swift` |
| Add JSON output to status | `StatusCommand.swift` |
| Improve terminal output styling | `ANSIColors.swift` and `Logger.swift` |

When in doubt, start with `macvivid fix --dry-run --verbose` to see what the tool detects and what it would do, then trace that into the source.
