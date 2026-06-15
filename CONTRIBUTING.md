# Contributing to MacVivid

Thank you for your interest in contributing to MacVivid!  
Every contribution — whether it's a bug fix, feature, or documentation improvement — is greatly appreciated.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Submitting Changes](#submitting-changes)
- [Coding Guidelines](#coding-guidelines)
- [Commit Message Convention](#commit-message-convention)

---

## Code of Conduct

Please be respectful and constructive in all interactions. We follow a simple rule:  
**Treat others the way you want to be treated.**

---

## How Can I Contribute?

### Reporting Bugs

Before submitting a bug report:
- Check [existing issues](https://github.com/etherian3/MacVivid/issues) to avoid duplicates
- Make sure you're on the latest version

Use the **Bug Report** issue template and include:
- macOS version and Mac model (e.g., MacBook Pro M2, macOS 14.5)
- Monitor name and connection method (e.g., HDMI via USB hub)
- Steps to reproduce the problem
- Expected vs actual behavior
- Output of `macvivid status --verbose`

### Requesting Features

Use the **Feature Request** issue template.  
Describe the problem you're trying to solve — not just the solution. This helps us understand the context and design a better solution together.

### Submitting Code

1. Open an issue first to discuss the change (skip for small fixes like typos)
2. Fork the repository
3. Create a branch from `main`
4. Make your changes
5. Submit a Pull Request

---

## Development Setup

### Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9+ (via Xcode or Command Line Tools)

### Install Xcode Command Line Tools

```bash
xcode-select --install
```

### Clone and Build

```bash
# Fork and clone your fork
git clone https://github.com/YOUR_USERNAME/MacVivid.git
cd MacVivid

# Build in debug mode
swift build

# Run directly
swift run macvivid --help

# Build release binary
swift build -c release
```

### Run During Development

```bash
# Quick test without installing
.build/debug/macvivid status
.build/debug/macvivid fix --dry-run
```

---

## Project Structure

```
MacVivid/
├── Sources/
│   └── macvivid/
│       ├── MacVivid.swift         # Root CLI entry point
│       ├── Commands/              # CLI subcommands (fix, status, revert, protect...)
│       ├── Core/                  # Core logic (gamma, display, watchdog...)
│       └── Utilities/             # Shared helpers and extensions
├── Package.swift                  # Swift Package Manager config
├── README.md
└── CONTRIBUTING.md
```

### Key Concepts

| Module | Responsibility |
|---|---|
| `Commands/` | CLI argument parsing (uses swift-argument-parser) |
| `Core/` | CoreGraphics gamma table manipulation |
| `Utilities/` | Logging, file I/O, helper functions |

---

## Submitting Changes

### 1. Fork & Branch

```bash
# Create a descriptive branch name
git checkout -b fix/monitor-detection-hdmi
git checkout -b feat/per-monitor-presets
git checkout -b docs/update-readme
```

### 2. Make Your Changes

- Write clean, readable Swift code
- Add comments for non-obvious logic (especially anything touching CoreGraphics)
- Test your changes manually with `macvivid fix --dry-run` and `macvivid status`

### 3. Open a Pull Request

- Fill in the PR template
- Reference any related issues with `Closes #123` or `Fixes #123`
- Describe **what** changed and **why**
- If it's a visual/behavioral change, include before/after output or screenshots

---

## Coding Guidelines

- Follow standard Swift conventions (Swift API Design Guidelines)
- Keep functions small and focused — one responsibility per function
- Prefer `guard` for early exits over deeply nested `if` blocks
- Use meaningful variable names — avoid single-letter names except for loop indices
- Do **not** modify system files or plists without explicit user consent
- Always test with `--dry-run` when developing fix/revert logic

### Example: Good vs Bad

```swift
// Good
guard let display = displays.first else { return }
applyGammaFix(to: display, intensity: .normal)

// Bad
if displays.count > 0 {
    let d = displays[0]
    fix(d, 1)
}
```

---

## Commit Message Convention

Use the following format:

```
<type>: <short description>

[optional body]
[optional footer]
```

### Types

| Type | When to use |
|---|---|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructure (no feature/fix) |
| `chore` | Tooling, deps, CI changes |
| `test` | Adding or updating tests |

### Examples

```
feat: add --intensity flag to fix command
fix: prevent crash when no external monitor detected
docs: add per-monitor preset usage to README
refactor: extract gamma table logic into GammaEngine
chore: update swift-argument-parser to 1.5.0
```

---

## Questions?

Open a [Discussion](https://github.com/etherian3/MacVivid/discussions) or an issue labeled `question`.  
We're happy to help!
