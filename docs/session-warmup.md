# Session warmup

Flame button opens cold Codex **5-hour** rate-limit windows with one minimal Responses request per eligible account.

OpenAI may temporarily omit `limit_window_seconds == 18000` from Team `wham/usage` (only weekly present). GrandeBar still parses **both**:

- `18000` → Session 5h
- `604800` → Weekly

When 5h returns in the API, Session 5h UI and warm skip logic light up again automatically.
