# GrandeBar

Native macOS menu bar app for CLIProxyAPI users who want Codex quota and local token cost at a glance.

GrandeBar is designed for this setup:

- [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) runs your Codex/OpenAI CLI proxy and exposes the management API.
- [router-for-me/Cli-Proxy-API-Management-Center](https://github.com/router-for-me/Cli-Proxy-API-Management-Center) manages your accounts and quota from a web panel.
- Local token cost is computed by GrandeBar itself from Codex and Claude Code session transcripts, using [ccusage](https://github.com/ccusage/ccusage)-format pricing bundled in `Resources/ccusage.json`.

The app sits in your macOS menu bar, shows the combined session pool percentage, opens the management panel quickly, and copies a short quota/cost summary when needed.

## Features

- Menu bar percentages for session (5h) and weekly quota pools.
- Compact popover with each account’s 5-hour session quota and weekly quota (5h shows `--` if API omits that window).
- Reset credit count and nearest reset expiry.
- One-click access to the Management Center quota page.
- Auto refresh: manual, 5, 10, 15, 30, or 60 minutes.
- Local token cost across **all Codex homes** (`~/.codex` + `codex-grande` / `aof` / `main` isolated profiles, `sessions` and `archived_sessions`) at standard pricing. Usage is the growth of each transcript's `total_token_usage`, so re-emitted `token_count` events are not counted twice.
- Copyable English summary with token cost, remaining quota, reset credits, and per-account remaining.
- **Manual session warm**: the flame button opens cold 5h windows through the configured remote management API.
- Header status lines: `N account · R reset` plus `locked · open · cold/warmed` detail.
- **Claude mode**: the Codex / Claude switch under the header shows Claude OAuth accounts from a (local) CLIProxyAPI with the same cards in an orange accent. Session 5h and weekly come from `api/oauth/usage`; accounts without a general weekly limit show their Fable weekly limit. The flame button warms cold Claude 5h windows with a one-token Haiku request, and the footer shows Claude Code cost computed from `~/.claude/projects` transcripts (subagents included, each response deduplicated to its final line).
- **Claude provider switch** (Claude mode only), one row per client:
  - `Code → claude.ai / CLIProxy` only edits the `env` block of `~/.claude/settings.json`; Claude Desktop is not touched. New Claude Code sessions pick it up.
  - `Desktop → <account> / CLIProxy` routes Claude Desktop through the CLIProxyAPI (third-party gateway profile, with `toolSearchEnabled` so Code sessions keep MCP tool search) or back to claude.ai. Claude Desktop is fully restarted, Code session processes included, because those processes keep the previous mode's environment. Each touched settings file is backed up once as `*.grandebar.bak`.
- **Claude Desktop accounts** (the account chip's menu): switch Claude Desktop between saved claude.ai logins without signing in again, the way codex-keyring swaps `~/.codex/auth.json`. GrandeBar keeps an opaque copy of each login in `~/Library/Application Support/GrandeBar/ClaudeDesktop/accounts/<name>/`. A copy holds the still-encrypted `oauth:tokenCache` / `oauth:tokenCacheV2` values from Desktop's `config.json`, plus `Cookies`, `Local Storage`, `Session Storage` and `IndexedDB`; tokens are never decrypted. A switch quits Desktop, saves the outgoing account's current state, restores the target and relaunches Desktop. `Add Account…` reopens Desktop at its sign-in screen and restores the previous login if sign-in is cancelled or takes longer than 5 minutes. `Save Current Login…` names the account that is already signed in. The file layout follows [claude-acc](https://github.com/ohmaseclaro/claude-acc).
  - Every action that quits Claude Desktop (account switch, adding an account, route switch) first lists the Code sessions that are working or waiting for you, read from Claude Code's `~/.claude/sessions` records. When there are any, the dialog turns critical and Return cancels. While Desktop waits for a new sign-in, a floating window shows the time left and a Cancel button.
  - Names are optional: an empty name uses the account's email (taken from the CLIProxy profile of the same account, or from Claude Code's `~/.claude.json` login), else a short account id. `Rename` changes a saved name; the menu shows each account's email next to its name.
- **Shared Code sessions** (opt-in, the `Sessions → separate / shared` row on the Claude card, the Desktop account menu or Settings): mirrors the Code-tab session list in `claude-code-sessions/<account>/<org>/` across every Claude Desktop account and the CLIProxy (`Claude-3p`) profile, so each account lists the same sessions. The transcripts already live in the account-agnostic `~/.claude/projects`. Turning it on imports right away; GrandeBar then syncs every 10 seconds, and while Desktop is closed for an account or route switch. The newest copy of a session wins and a deleted session is deleted everywhere. Chat-tab conversations stay on claude.ai and Cowork sessions are not shared.
- **Active account in the menu bar** (Claude mode): while Claude Desktop (or, failing that, Claude Code) is signed into claude.ai, the menu bar shows that account's 5h and weekly percentages and marks its row with a dot. Through CLIProxy it shows the pool total.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools or a Swift toolchain with `swiftc`.
- A running CLIProxyAPI-compatible management endpoint.
- A management key for that endpoint.

## Install with Homebrew

Download the macOS ZIP from the latest GitHub Release, extract it, and move GrandeBar.app to Applications. Right-click the menu bar icon to check for updates manually. GrandeBar also checks for new releases after launch and every 6 hours, asks before installation, verifies the release ZIP checksum and app bundle, then restarts. Updates require write access to the installed app location.

```bash
brew install --cask grandeand/tap/grandebar
```

The current release is unsigned. Homebrew can install it, but macOS may warn on first launch because the app is not signed and notarized yet.

If macOS says the app is damaged or should be moved to Trash, remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/GrandeBar.app
```

You can also install without quarantine:

```bash
brew install --cask --no-quarantine grandeand/tap/grandebar
```

## Setup

1. Install and run CLIProxyAPI.

Follow the CLIProxyAPI repository instructions, add your Codex accounts, and make sure the management API is enabled.

2. Open the Management Center.

The default GrandeBar base URL is:

```text
http://localhost:8317
```

GrandeBar expects the panel and API to be available under the same origin:

```text
/management.html#/quota
/v0/management/auth-files
/v0/management/api-call
```

3. Build the app.

```bash
./build.sh
open dist/GrandeBar.app
```

4. Configure GrandeBar.

On first launch, GrandeBar asks for the Management Center URL and management key. You can change them later from Settings.

Right-click the menu bar icon, open `Settings`, then set:

- `Base URL`: your CLIProxyAPI Management Center origin, for example `http://localhost:8317`.
- `Management key`: your management API key.
- `Auto refresh`: optional refresh interval.
- `Appearance`: Auto, Light, or Dark.
- `Language`: System, English, or Türkçe.
- `Launch at Login`: optional macOS login item.

## How It Works

GrandeBar asks the management API for active auth files, then uses the management API proxy endpoint to request Codex quota data for each account. It reads local token cost separately through `ccusage`.

No management key is stored in the app bundle. The key is saved in macOS user defaults for the current user.

## Security Notes

- Do not expose your CLIProxyAPI management endpoint publicly without proper protection.
- Treat the management key like a secret.
- GrandeBar does not include, publish, or bundle any account token.

## Session window warmup (multi-account)

Codex 5-hour limits start on first real usage per account. Automatic warmup is disabled, but the flame button can manually warm eligible accounts through the configured API Base.

**CLI (optional):**

```bash
python3 scripts/session_warmup.py --dry-run
python3 scripts/session_warmup.py --yes
```

Details: [docs/session-warmup.md](docs/session-warmup.md).

## Development

This is a small AppKit app with no package manager dependency.

```bash
./build.sh
```

The built app is written to:

```text
dist/GrandeBar.app
```

## Compatibility

GrandeBar targets the management API shape used by CLIProxyAPI and the CLI Proxy API Management Center. Other backends can work if they provide the same management endpoints and response shapes.
