# Session warmup

Flame button opens cold Codex **5-hour** rate-limit windows with one minimal Responses request per eligible account.

OpenAI may temporarily omit `limit_window_seconds == 18000` from Team `wham/usage` (only weekly present). GrandeBar still parses **both**:

- `18000` → Session 5h
- `604800` → Weekly

When 5h returns in the API, Session 5h UI and warm skip logic light up again automatically.

## Automatic warmup

Automatic session warmup is enabled by default in Settings. GrandeBar uses the nearest account's reported `reset_after_seconds`, waits 120 seconds for the server-side window to settle, then runs the existing eligible-account warmup flow. After quota data refreshes, the next run is scheduled from the new reset values.

Cold accounts are warmed immediately on startup. If macOS sleeps past a scheduled run, GrandeBar checks again when the Mac wakes. When the API temporarily omits the 5-hour window, it retries after 15 minutes.
