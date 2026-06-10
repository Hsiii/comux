<div align="center">
  <img src="assets/logo.png" alt="comux logo" width="160" />

<h1>comux</h1>

A macOS menu bar app to track and sort your Codex account limits at a glance.

<img src="assets/demo.png" alt="comux demo" height="720" />
</div>

## Why comux

- **Zero Setup:** Picks up local Codex sessions automatically and refreshes usage in the background, no manual setup required.
- **Unified Tracking:** See usage across multiple Codex accounts and workspaces in one menu bar view, without bouncing between sessions.
- **Plan your Usage:** Accounts are ranked by remaining headroom, making it obvious which account to use next.
- **Privacy First:** Keep account details readable without exposing more than you need. comux supports custom display names and stores account metadata locally in a native on-disk SQLite database, so your account inventory stays private, durable, and under your control.

## Install

comux does not currently ship notarized macOS builds. To build a local DMG:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install xcodegen
./scripts/package-dmg.sh
```

The resulting DMG is ad-hoc signed for local use, not Developer ID signed for redistribution.

## Development

Run directly:

```bash
swift run comux
```

Build the native macOS app bundle:

```bash
./scripts/build-app.sh
```

Build a DMG for distribution:

```bash
./scripts/package-dmg.sh
```
