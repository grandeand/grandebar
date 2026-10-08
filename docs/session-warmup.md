# Session warmup

Flame button opens cold Codex **5-hour** rate-limit windows with one minimal Responses request per eligible account.

OpenAI may temporarily omit `limit_window_seconds == 18000` from Team `wham/usage` (only weekly present). GrandeBar still parses **both**:

- `18000` → Session 5h
- `604800` → Weekly

When 5h returns in the API, Session 5h UI and warm skip logic light up again automatically.

## Automatic warmup

Automatic session warmup is enabled by default in Settings. GrandeBar uses the nearest account's reported `reset_after_seconds` and waits a random 1-10 minutes past the reset (so warms land 301-310 minutes apart, never on a fixed beat), then runs the existing eligible-account warmup flow. Cold accounts are warmed after a random 20-90 seconds; if an account is still cold after an automatic run, the next one waits 10 minutes. After quota data refreshes, the next run is scheduled from the new reset values.

If macOS sleeps past a scheduled run, GrandeBar checks again when the Mac wakes. When the API temporarily omits the 5-hour window, it retries after 15 minutes.

## Claude mode

The flame button and automatic warmup also work in Claude mode: a cold Claude account (no `resets_at` on its session limit) gets one `max_tokens: 1` Haiku request through the management `api-call`, which starts its 5-hour window. Codex and Claude have separate automatic warmup toggles in Settings; the mode that is not on screen is warmed and rescheduled in the background.
