# TODO / FIXME / HACK / XXX and Swift Size Inventory

## Summary

- **Base commit:** `aa7592a` (`main`)
- **Comment marker scope:** `Sources/` (13 files) and `scripts/` (3 files) — 16 files total
- **Comment markers found (`TODO`, `FIXME`, `HACK`, `XXX`):** **0**
- **Swift files under `Sources/`:** **13** files, **9,236** total lines
- **Largest Swift file:** `Sources/GrandeBar.swift` (6,652 lines)

## Comment Markers (`Sources/` and `scripts/`)

### Counts by Marker

| Marker | Count |
|---|---:|
| `TODO` | 0 |
| `FIXME` | 0 |
| `HACK` | 0 |
| `XXX` | 0 |
| **Total** | **0** |

### Matches Grouped by File

No `TODO`, `FIXME`, `HACK`, or `XXX` comments were found in any file under `Sources/` or `scripts/`.

#### Scanned Files (0 matches each)

- `Sources/ChiefMove.swift` — 0
- `Sources/ClaudeDesktopAccounts.swift` — 0
- `Sources/ClaudeDesktopToken.swift` — 0
- `Sources/ClaudeLimitResets.swift` — 0
- `Sources/ClaudeLimitsTab.swift` — 0
- `Sources/ClaudeSessionSharing.swift` — 0
- `Sources/GrandeBar.swift` — 0
- `Sources/GrandeBarUpdater.swift` — 0
- `Sources/GrandeClaudex.swift` — 0
- `Sources/LocalCosts.swift` — 0
- `Sources/QuotaFile.swift` — 0
- `Sources/WeeklyPace.swift` — 0
- `Sources/main.swift` — 0
- `scripts/ccusage-all-codex.sh` — 0
- `scripts/install-update.sh` — 0
- `scripts/session_warmup.py` — 0

#### Excluded Non-Comment Substring Matches

An unfiltered substring search for `XXX` matches two `mktemp` template strings in code (not comments and not `XXX` markers):

- `scripts/install-update.sh:32` — `incoming=$(mktemp -d "$parent_dir/.grandebar-incoming.XXXXXX")`
- `scripts/install-update.sh:65` — `backup=$(mktemp -d "$parent_dir/.grandebar-backup.XXXXXX")`

## Swift Files Under `Sources/` by Line Count

Sorted from largest to smallest (`wc -l`, matching newline-delimited line count across all files):

| Rank | File | Lines |
|---:|---|---:|
| 1 | `Sources/GrandeBar.swift` | 6,652 |
| 2 | `Sources/ClaudeSessionSharing.swift` | 703 |
| 3 | `Sources/ClaudeDesktopAccounts.swift` | 656 |
| 4 | `Sources/GrandeClaudex.swift` | 318 |
| 5 | `Sources/ChiefMove.swift` | 204 |
| 6 | `Sources/GrandeBarUpdater.swift` | 154 |
| 7 | `Sources/ClaudeDesktopToken.swift` | 130 |
| 8 | `Sources/QuotaFile.swift` | 128 |
| 9 | `Sources/WeeklyPace.swift` | 106 |
| 10 | `Sources/ClaudeLimitResets.swift` | 91 |
| 11 | `Sources/LocalCosts.swift` | 57 |
| 12 | `Sources/ClaudeLimitsTab.swift` | 28 |
| 13 | `Sources/main.swift` | 9 |
| | **Total (13 files)** | **9,236** |
