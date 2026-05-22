<div align="center">
  <img src="assets/logo.png" alt="CodexMux logo" width="160" />

<h1>CodexMux</h1>

A macOS menu bar app to track and sort your Codex account limits at a glance.

<img src="assets/demo.png" alt="CodexMux demo" height="720" />
</div>

## Why
Codex usage is easy to lose track of when you work across personal and team
accounts, multiple workspaces, or different reset windows. CodexMux turns that
into one local control panel so you do not have to keep checking each account
manually.

## Features

- Reads Codex sessions from `~/.codex/auth.json`
- Automatically tracks and caches account usage and reset times
- Arranges accounts by usage pressure and nearest reset
- Supports nicknames to keep email addresses off-screen
- Lets you enable "Open at Login" from the app on macOS

## Install

Launch the app bundle tracked in this repo directly:

```bash
open CodexMux.app
```

Or open the DMG in the repo root and drag the app into `/Applications`:

```bash
open CodexMux-0.1.0.dmg
```

## Development

Run directly:

```bash
swift run CodexMux
```

Build the native macOS app bundle:

```bash
./scripts/build-app.sh
open CodexMux.app
```

Build a DMG for distribution:

```bash
./scripts/package-dmg.sh --version 0.1.0
```

That command also copies the final DMG to the repo root so it can be opened directly from there.
