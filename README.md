# GrandeBar

Native macOS menu bar app for CLIProxyAPI users who want Codex quota and local token cost at a glance.

GrandeBar is designed for this setup:

- [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) runs your Codex/OpenAI CLI proxy and exposes the management API.
- [router-for-me/Cli-Proxy-API-Management-Center](https://github.com/router-for-me/Cli-Proxy-API-Management-Center) manages your accounts and quota from a web panel.
- [ccusage/ccusage](https://github.com/ccusage/ccusage) reads local Codex usage and cost.

The app sits in your macOS menu bar, shows the combined session pool percentage, opens the management panel quickly, and copies a short quota/cost summary when needed.

## Features

- Menu bar percentage from the total session pool.
- Compact popover with each account's 5-hour session quota and weekly quota.
- Reset credit count and nearest reset expiry.
- One-click access to the Management Center quota page.
- Auto refresh: manual, 5, 10, 15, 30, or 60 minutes.
- Local token cost from `ccusage`.
- Copyable English summary with token cost, total remaining quota, reset credits, and per-account remaining quota.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools or a Swift toolchain with `swiftc`.
- A running CLIProxyAPI-compatible management endpoint.
- A management key for that endpoint.
- `ccusage` installed as an executable available to the app.

GrandeBar looks for `ccusage` in:

- `~/.npm-global/bin/ccusage`
- `/opt/homebrew/bin/ccusage`
- `/usr/local/bin/ccusage`
- the app process `PATH`

## Install with Homebrew

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

3. Install `ccusage`.

Use the install method from the `ccusage` repository, then verify that this command works in your terminal:

```bash
ccusage codex daily --json --offline
```

4. Build the app.

```bash
./build.sh
open dist/GrandeBar.app
```

5. Configure GrandeBar.

On first launch, GrandeBar asks for the Management Center URL and management key. You can change them later from Settings.

Right-click the menu bar icon, open `Settings`, then set:

- `Base URL`: your CLIProxyAPI Management Center origin, for example `http://localhost:8317`.
- `Management key`: your management API key.
- `Auto refresh`: optional refresh interval.
- `Appearance`: Auto, Light, or Dark.
- `Language`: System, English, or Türkçe.
- `Launch at Login`: optional macOS login item.

## How It Works

GrandeBar asks the management API for active auth files, then uses the management API proxy endpoint to request Codex quota data for each account. It reads local token cost separately through `ccusage` in offline mode.

No management key is stored in the app bundle. The key is saved in macOS user defaults for the current user.

## Security Notes

- Do not expose your CLIProxyAPI management endpoint publicly without proper protection.
- Treat the management key like a secret.
- GrandeBar does not include, publish, or bundle any account token.

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
