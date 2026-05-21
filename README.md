# CodexMux

CodexMux is a native macOS menu bar app for people who use Codex across more
than one account or workspace and want one place to see which account still has
the best headroom.

Instead of checking usage windows one account at a time, CodexMux syncs them
into one local dashboard, keeps short history, and surfaces the accounts that
need attention first.

## Why it is useful

- The current Codex account is picked up automatically from your local Codex
  session.
- Extra ChatGPT/Codex accounts can be added with their own cookies.
- Weekly and rolling 5-hour limits are normalized into the same view.
- The menu sorts accounts by urgency, so the accounts under the most pressure
  rise to the top.
- Everything is cached locally, so the UI reads from disk instead of waiting on
  network requests every time you open it.

## How syncing works

CodexMux combines two sync paths:

1. `~/.codex/auth.json` is read for the current ambient Codex session.
2. Optional extra accounts are loaded from `~/.codexmux/accounts.json`.

For each account, the app:

- gets an access token
- fetches usage from `https://chatgpt.com/backend-api/wham/usage`
- resolves the workspace name when available
- converts the response into one shared local schema
- writes the merged result to `~/.codexmux/cache.json`

The app UI reads from that cache file only.

## How accounts are merged

CodexMux treats an account identity as:

- `email + plan`

That means repeated syncs update the same logical account even if the raw
snapshot key changes underneath. The saved history is appended only when usage
actually changes, and the app keeps the latest 12 history points per account.

This matters for first-time users because it means:

- your current system account and your configured extra accounts end up in one
  stable list
- repeated refreshes do not create duplicate dashboard cards
- nicknames stay useful because the same person/account keeps collapsing into
  the same entry

## How sorting works

The menu is not alphabetical first.

Accounts are ordered by:

1. weekly usage pressure versus where the account is expected to be in its reset
   cycle
2. nearest weekly reset time
3. display name

In practice, this pushes the accounts that are most ahead of their expected
weekly burn to the top, which makes the dashboard useful as a routing tool, not
just a passive meter board.

## First run

Run the app directly:

```bash
cd /Users/hsi/Documents/Projects/Personal/CodexBoard
swift run CodexMux
```

Or build a normal `.app` bundle:

```bash
cd /Users/hsi/Documents/Projects/Personal/CodexBoard
./scripts/build-app.sh
open .build/apple/CodexMux.app
```

On first launch, CodexMux will create:

- `~/.codexmux/cache.json`

If you do nothing else, the app will still show the current account from your
local Codex session.

## Adding extra accounts

Create `~/.codexmux/accounts.json` and add one object per extra account.

Minimal example:

```json
{
  "pollIntervalSeconds": 300,
  "accounts": [
    {
      "id": "work-pro",
      "label": "Work Pro",
      "email": "me@company.com",
      "workspaceLabel": "Company",
      "plan": "Codex Pro",
      "color": "#7cc6ff",
      "chatGPTCookie": "YOUR_CHATGPT_COOKIE"
    }
  ]
}
```

Supported fields come from [`AccountConfig`](./src/Model.swift):

- `id`: stable local ID for that configured account
- `label`: default display label before nicknames
- `email`: used as part of merge identity
- `workspaceLabel`: fallback workspace name if the API does not return one
- `plan`: used for display and merge identity
- `color`: card accent color
- `chatGPTCookie`: required for extra accounts
- `source`, `sessionEndpoint`, `usageEndpoint`, `accountHeader`: optional

Use `accountHeader` when a specific ChatGPT account/workspace header is needed.

## Local data and customization

- Cache is stored at `~/.codexmux/cache.json`.
- Extra account config is stored at `~/.codexmux/accounts.json`.
- Nicknames are stored locally in `UserDefaults`.
- The ambient system account does not need cookie configuration.

## Product model in one sentence

CodexMux is useful because it turns scattered, per-account Codex usage checks
into one ranked local control panel, so you can decide where to work next
without manually opening and comparing every account.
