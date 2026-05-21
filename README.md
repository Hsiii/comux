# CodexMux

CodexMux is a native macOS menu bar utility for tracking Codex usage across
multiple accounts.

## What it does

- reads the current system account automatically from `~/.codex/auth.json`
- fetches extra accounts independently with per-account ChatGPT cookies
- normalizes weekly and rolling 5-hour usage into one local cache
- shows a compact native dashboard directly from the menu bar app
- stores snapshots in `~/.codexmux/cache.json`

## Architecture

1. The Swift app reads the ambient Codex bearer token from `~/.codex/auth.json`.
2. It refreshes usage from `https://chatgpt.com/backend-api/wham/usage`.
3. Optional extra accounts are fetched with their own ChatGPT cookies.
4. All snapshots are normalized into the same account schema.
5. The menu bar dashboard reads from the local cache file only.

## Run the app

```bash
cd /Users/hsi/Documents/Projects/Personal/CodexBoard
swift run CodexMux
```

## Build a Finder-openable app bundle

```bash
cd /Users/hsi/Documents/Projects/Personal/CodexBoard
./scripts/build-app.sh
open .build/apple/CodexMux.app
```

The packaging script assembles a lightweight `.app` bundle around the SwiftPM
binary so LaunchServices can open it like a normal macOS menu bar app.

## Extra accounts

1. Create `~/.codexmux/accounts.json`.
2. Add one object per extra account with its own ChatGPT cookie using the `AccountConfig` shape from [Model.swift](/Users/hsi/Documents/Projects/Personal/CodexBoard/src/Model.swift).
3. Run the app.

## Notes

- The current system account needs no cookie config.
- Nicknames are stored locally in `UserDefaults`.
- The app creates an empty local cache at `~/.codexmux/cache.json` on first run.
