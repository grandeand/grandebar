# Session warmup (removed)

The flame **session warmup** feature opened cold Codex **5-hour** rate-limit windows with one minimal Responses request per account.

As of GrandeBar **0.2.5**, OpenAI’s Team `wham/usage` payload no longer exposes a 5h (`limit_window_seconds == 18000`) window (only weekly / 7d). Warmup and Session 5h UI were removed accordingly.

If OpenAI restores a short rolling window later:

1. Re-introduce parsing for `limit_window_seconds == 18000` (or the new value) in `QuotaAPI`.
2. Restore per-account short-window metric + optional pool.
3. Optionally restore warmup (`SessionWarmupAPI`) from git history around `v0.2.4`.
