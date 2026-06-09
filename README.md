# MacVivid

**Fix washed out colors on your external monitor — with one command.**

MacVivid is a free, open-source macOS CLI tool that fixes the common "washed out colors" problem on external monitors. When macOS misidentifies your monitor as a TV, it uses YCbCr Limited Range instead of RGB Full Range, making colors look faded, dull, and text blurry. MacVivid fixes this instantly with a gamma compensation curve.

---

<img width="800" height="450" alt="IMG_9236" src="https://github.com/user-attachments/assets/41dd9842-03aa-4c42-a77e-db30512b27bd" />

---
## The Problem

- External monitor colors look washed out, faded, or grayish
- Text appears blurry or fuzzy compared to the built-in Retina display
- Colors seem less vibrant — reds, greens, blues all look pale
- Light gray areas appear washed into white; dark areas look muddy

This happens because macOS often misdetects external monitors (especially via HDMI or USB hubs) as TVs and applies YCbCr Limited Range instead of RGB Full Range.

Common affected setups:

- MacBook + External Monitor via USB Hub to HDMI
- Apple Silicon Macs (M1, M2, M3, M4)
- After sleep, cable reconnect, or reboot

---

## Installation

### Build from Source

```bash
# Clone the repository
git clone https://github.com/etherian3/MacVivid.git
cd MacVivid

# Build release binary
swift build -c release

# Install to your PATH (requires sudo)
sudo cp .build/release/macvivid /usr/local/bin/

# Verify installation
macvivid --version
```

### Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1/M2/M3/M4) or Intel Mac
- Swift 5.9+ (included with Xcode Command Line Tools)

---

## Usage

### Check Monitor Status

```bash
macvivid status
```

Shows all connected monitors with their color mode, connection type, HDR status, and whether the MacVivid fix is currently active.

Options:

- `--verbose` / `-v` Show debug output
- `--json` Output in JSON format (for scripting)

### Fix Washed Out Colors

```bash
# Fix the first detected external monitor
macvivid fix

# Fix a specific monitor by name
macvivid fix --monitor "MSI"

# Fix all external monitors at once
macvivid fix --all

# Choose fix intensity
macvivid fix --intensity light    # Minimal: only fixes black level
macvivid fix --intensity normal   # Moderate: fixes black + adds contrast (recommended)
macvivid fix --intensity strong   # Maximum: full contrast + gamma boost

# Preview changes without applying (safe dry run)
macvivid fix --dry-run

# See all fix options
macvivid fix --help
```

### Revert Changes

```bash
# Revert all changes and restore original color settings
macvivid revert

# Revert a specific monitor by name
macvivid revert --monitor "MSI"

# List all available backups
macvivid revert --list

# Revert to a specific backup snapshot
macvivid revert --backup 2026-06-06_225600
```

### Protect Settings (Persist Through Sleep / Reboot)

The fix is lost when the system sleeps or reboots. Use protect to keep it running in the background:

```bash
# Start background watchdog to re-apply fix automatically
macvivid protect

# Stop the background watchdog
macvivid unprotect
```

### Help

```bash
# Global help
macvivid --help

# Per-command help
macvivid fix --help
macvivid status --help
macvivid revert --help
macvivid protect --help
macvivid unprotect --help
```

---

## How It Works

MacVivid applies a gamma compensation curve directly to the display hardware via the macOS CoreGraphics API:

1. **Black Level Correction** — Lifts the input floor from 16/255 to 0/255, making blacks truly black instead of muddy gray (fixes the Limited Range problem)
2. **Smooth S-Curve Contrast** — Applies a mathematically smooth contrast boost that makes colors more vivid without crushing highlights or destroying shadow detail
3. **Watchdog Protection** — Optional background daemon that re-applies the fix whenever the system wakes from sleep or the monitor reconnects

All changes operate in software only. The fix is reverted simply by running `macvivid revert` or rebooting without protect enabled.

---

## Fix Intensity Levels

| Intensity | Black Offset | Contrast Boost       | Best For                             |
| --------- | ------------ | -------------------- | ------------------------------------ |
| `light`   | Very subtle  | None                 | Minor fading, near-correct monitors  |
| `normal`  | Moderate     | +25% S-Curve         | Most external monitors (recommended) |
| `strong`  | Strong       | +35% S-Curve + gamma | Severely washed out displays         |

---

## File Locations

| Path                      | Purpose                     |
| ------------------------- | --------------------------- |
| `~/.macvivid/backups/`    | Configuration backups       |
| `~/.macvivid/logs/`       | Log files                   |
| `~/.macvivid/protection/` | Watchdog protection configs |

---

## Safety

- No system files are modified (no plist edits, no EDID overrides by default)
- Full revert with a single command: `macvivid revert`
- Dry run mode available: `macvivid fix --dry-run`
- All actions are logged to `~/.macvivid/logs/`

---

## Roadmap

- [x] Phase 1: CLI tool with gamma compensation
- [ ] Phase 2: Stabilization and per-monitor presets
- [ ] Phase 3: Menu bar GUI (SwiftUI)
- [ ] Phase 4: Advanced features (manual color profiles, DDC brightness control)
- [ ] Phase 5: HiDPI helper and display management

---

## Contributing

Contributions are welcome. Please open an issue first to discuss the change, then submit a Pull Request.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

## Acknowledgments

- CGSetDisplayTransferByTable (CoreGraphics) for gamma table access
- [displayplacer](https://github.com/jakehilborn/displayplacer) for display management inspiration
