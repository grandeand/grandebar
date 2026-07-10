# Session Window Warmup

## Problem

Codex 5-hour rate limits are **rolling windows anchored to the first real usage** on each account, not a shared wall clock.

With a multi-account CLIProxyAPI pool:

1. Work traffic often hits one account first.
2. That account’s 5h timer starts; cold accounts stay idle.
3. Fast burn can empty the pool while remaining accounts never opened their window in the same work block.
4. Resets then land at staggered times.

## Goal

At work start (or on demand), send **one minimal Codex request per eligible account**, pinned by `authIndex`, so every account’s 5h session window opens in the same block.

## What does **not** open a window

- `GET https://chatgpt.com/backend-api/wham/usage` (GrandeBar quota polling)
- Management API listing endpoints

## What opens a window (spike result)

Verified via CLIProxyAPI management `POST /v0/management/api-call`:

| Field | Value |
|--------|--------|
| URL | `https://chatgpt.com/backend-api/codex/responses` |
| Method | `POST` |
| `stream` | **must be `true`** (non-stream returns `400 Stream must be set to true`) |
| Model | `gpt-5.4-mini` (resolves to `gpt-5.4-mini-2026-03-17`) |
| Reasoning | `{"effort":"none"}` |
| Prompt | `"hi"` + instruction “Reply with exactly: ok” |
| Observed cost | ~16 input + ~5 output ≈ **21 total tokens** |
| Integer session `%` | often **+0** (below 1% granularity) — still valid usage |

Headers:

- `Authorization: Bearer $TOKEN$` (management substitutes the account token)
- `ChatGPT-Account-Id` / `chatgpt-account-id` from usage payload
- `Accept: text/event-stream`
- `OpenAI-Beta: responses=experimental`
- `originator: codex_cli_rs`

Unsupported (400): `max_output_tokens` on this Codex path.

## Skip rules (default)

Warm is **not** a re-align of already-open windows (that only burns quota).

| Condition | Action |
|-----------|--------|
| `disabled` | skip |
| `allowed=false` / credits depleted | skip |
| `limit_reached` | skip (unless `--force`) |
| `session used% > --idle-max-used` (default 0) | skip as “already open” |
| `--force` | ignore open/limit skips carefully |

Default `idle-max-used=0` means only accounts at **0% used** are warmed.  
If you want “almost idle” accounts too: `--idle-max-used 1`.

## GrandeBar UI

Header toolbar (left of refresh):

- **Flame** button → confirms, then warms all **cold** accounts (same skip rules as the CLI).
- Shows a summary alert (warmed / skipped / failed), then refreshes quota.

Per-account warm buttons are planned next; not in this build.

## CLI

```bash
cd /Users/samethasturk/Desktop/Grande/grandebar

# Preview targets
python3 scripts/session_warmup.py --dry-run

# Live warm (confirm prompt)
python3 scripts/session_warmup.py

# Non-interactive
python3 scripts/session_warmup.py --yes

# Only some accounts
python3 scripts/session_warmup.py --yes --only grandecorpo,hasturk

# Force even if already open (costs quota)
python3 scripts/session_warmup.py --yes --force --only fatihmehmet
```

Config resolution:

1. `--base` / `--key`
2. `GRANDEBAR_API_BASE` / `GRANDEBAR_MGMT_KEY`
3. macOS prefs `co.grande.grandebar` (`apiBase`, `managementKey`)

## Recommended workflow

1. Start of work block → `python3 scripts/session_warmup.py --dry-run`
2. Confirm cold accounts listed as dry-run targets
3. `python3 scripts/session_warmup.py --yes`
4. Open GrandeBar / refresh quota — session pool should show more active windows with aligned `reset_after`

## Safety

- One request per account per run
- Cheapest practical model (`gpt-5.4-mini`)
- Default skips open/depleted accounts
- No secrets printed
- Does not change CLIProxyAPI routing (round-robin/sticky remains separate)

## Future (not in MVP)

- GrandeBar “Warm sessions” button + settings
- Optional launch-at-work-hours / notify when ≥N accounts idle
- Automatic re-open at reset boundary (CodexBar #951 style daily double-window)
