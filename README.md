<div align="center">
  <img src="assets/logo.png" alt="CodexMux logo" width="160" />

<h1>CodexMux</h1>

A macOS menu bar app to track and sort your Codex account limits at a glance.

<img src="assets/demo.png" alt="CodexMux demo" height="480" />
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

## Install

Launch the app bundle tracked in this repo:

```bash
open CodexMux.app
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
