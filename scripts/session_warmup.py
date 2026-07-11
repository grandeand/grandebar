#!/usr/bin/env python3
"""Warm Codex 5-hour session windows across CLIProxyAPI auth accounts.

Opens (or verifies) the rolling 5h rate-limit window on each eligible account by
sending one minimal ChatGPT Codex Responses request, pinned via management
api-call + authIndex.

Config (priority: CLI flags > env > GrandeBar macOS prefs):
  GRANDEBAR_API_BASE / --base
  GRANDEBAR_MGMT_KEY / --key

Examples:
  python3 scripts/session_warmup.py --dry-run
  python3 scripts/session_warmup.py --yes
  python3 scripts/session_warmup.py --yes --only samet@grandecorpo.com
  python3 scripts/session_warmup.py --yes --force
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Any


DEFAULT_MODEL = "gpt-5.4-mini"
DEFAULT_IDLE_MAX_USED = 0  # legacy CLI flag; timer progress is the real gate
DEFAULT_CONCURRENCY = 1
# Session primary window length (5h). A window is "progressing" only after the
# countdown has moved this many seconds off the full window — used% alone lies
# when API shows used=1% but reset still stuck at 18000.
SESSION_WINDOW_SECONDS = 18_000
PROGRESS_THRESHOLD_SECONDS = 120
USER_AGENT = "GrandeBar-Warmup/0.1"
CODEX_RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses"
USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
PREFS_DOMAIN = "co.grande.grandebar"


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

def _defaults_read(key: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["defaults", "read", PREFS_DOMAIN, key],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def resolve_base(cli: str | None) -> str:
    raw = (cli or os.environ.get("GRANDEBAR_API_BASE") or _defaults_read("apiBase") or "http://localhost:8317")
    raw = raw.strip()
    if not raw.startswith("http://") and not raw.startswith("https://"):
        raw = "https://" + raw
    return raw.rstrip("/")


def resolve_key(cli: str | None) -> str:
    key = (cli or os.environ.get("GRANDEBAR_MGMT_KEY") or _defaults_read("managementKey") or "").strip()
    if not key:
        raise SystemExit(
            "Management key missing. Set GRANDEBAR_MGMT_KEY, pass --key, "
            f"or configure GrandeBar prefs ({PREFS_DOMAIN})."
        )
    return key


# ---------------------------------------------------------------------------
# HTTP / management API
# ---------------------------------------------------------------------------

def management_json(
    base: str,
    key: str,
    path: str,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    timeout: float = 120.0,
) -> Any:
    url = f"{base}/v0/management{path}"
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return {}
            return json.loads(raw.decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {e.code} {path}: {body[:500]}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error {path}: {e}") from e


def parse_body(body: Any) -> dict[str, Any]:
    if isinstance(body, dict):
        return body
    if isinstance(body, str):
        try:
            obj = json.loads(body)
            return obj if isinstance(obj, dict) else {"_raw": body[:2000]}
        except json.JSONDecodeError:
            return {"_raw": body[:2000]}
    return {}


def as_int(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(round(float(value)))
    try:
        return int(round(float(str(value))))
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Domain models
# ---------------------------------------------------------------------------

@dataclass
class UsageSnapshot:
    email: str | None
    account_id: str | None
    allowed: bool | None
    limit_reached: bool | None
    session_used: int | None
    session_reset: int | None
    weekly_used: int | None
    plan_type: str | None = None
    rate_limit_reached_type: str | None = None

    def session_label(self) -> str:
        if self.session_used is None:
            return "--"
        return f"{self.session_used}%"


@dataclass
class AuthAccount:
    auth_index: str
    account: str
    name: str
    disabled: bool


@dataclass
class WarmResult:
    account: str
    auth_index: str
    action: str  # warmed | skipped | failed | dry-run
    note: str
    before: UsageSnapshot | None = None
    after: UsageSnapshot | None = None
    status_code: int | None = None
    elapsed_s: float | None = None
    tokens: dict[str, int] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Usage + trigger
# ---------------------------------------------------------------------------

def fetch_usage(base: str, key: str, auth_index: str) -> UsageSnapshot:
    resp = management_json(
        base,
        key,
        "/api-call",
        method="POST",
        payload={
            "authIndex": auth_index,
            "method": "GET",
            "url": USAGE_URL,
            "header": {
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "codex_cli_rs/0.76.0",
            },
        },
        timeout=60,
    )
    status = resp.get("status_code")
    if status is not None and not (200 <= int(status) < 300):
        raise RuntimeError(f"usage HTTP {status}: {str(resp.get('body'))[:300]}")

    body = parse_body(resp.get("body"))
    lim = body.get("rate_limit") or {}
    pw = lim.get("primary_window") or lim.get("primaryWindow") or {}
    sw = lim.get("secondary_window") or lim.get("secondaryWindow") or {}
    rlt = body.get("rate_limit_reached_type")
    if isinstance(rlt, dict):
        rlt_type = rlt.get("type")
    else:
        rlt_type = rlt

    return UsageSnapshot(
        email=body.get("email"),
        account_id=body.get("account_id") or body.get("accountId"),
        allowed=lim.get("allowed"),
        limit_reached=lim.get("limit_reached") if lim.get("limit_reached") is not None else lim.get("limitReached"),
        session_used=as_int(pw.get("used_percent") if pw.get("used_percent") is not None else pw.get("usedPercent")),
        session_reset=as_int(
            pw.get("reset_after_seconds") if pw.get("reset_after_seconds") is not None else pw.get("resetAfterSeconds")
        ),
        weekly_used=as_int(sw.get("used_percent") if sw.get("used_percent") is not None else sw.get("usedPercent")),
        plan_type=body.get("plan_type") or body.get("planType"),
        rate_limit_reached_type=str(rlt_type) if rlt_type else None,
    )


def list_auth_accounts(base: str, key: str) -> list[AuthAccount]:
    data = management_json(base, key, "/auth-files")
    files = data.get("files") or []
    out: list[AuthAccount] = []
    for f in files:
        auth_index = (f.get("auth_index") or f.get("authIndex") or "").strip()
        if not auth_index:
            continue
        account = (f.get("account") or f.get("name") or auth_index).strip()
        name = (f.get("name") or account).strip()
        disabled = bool(f.get("disabled"))
        out.append(AuthAccount(auth_index=auth_index, account=account, name=name, disabled=disabled))
    return out


def build_warmup_payload(model: str) -> dict[str, Any]:
    return {
        "model": model,
        "instructions": "Reply with exactly: ok",
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "hi"}],
            }
        ],
        "tools": [],
        "tool_choice": "none",
        "parallel_tool_calls": False,
        "store": False,
        "stream": True,
        "include": [],
        "reasoning": {"effort": "none"},
    }


def extract_usage_tokens(sse_body: str) -> dict[str, int]:
    """Best-effort parse of final response.completed usage from SSE body."""
    tokens: dict[str, int] = {}
    if not sse_body:
        return tokens
    for line in sse_body.splitlines():
        if not line.startswith("data:"):
            continue
        raw = line[5:].strip()
        if not raw or raw == "[DONE]":
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        response = event.get("response") if event.get("type") == "response.completed" else None
        if response is None and event.get("type") is None and "usage" in event:
            response = event
        if not isinstance(response, dict):
            continue
        usage = response.get("usage") or {}
        if not isinstance(usage, dict):
            continue
        for k_src, k_dst in (
            ("input_tokens", "input"),
            ("output_tokens", "output"),
            ("total_tokens", "total"),
        ):
            v = as_int(usage.get(k_src))
            if v is not None:
                tokens[k_dst] = v
        details = usage.get("output_tokens_details") or {}
        if isinstance(details, dict):
            rt = as_int(details.get("reasoning_tokens"))
            if rt is not None:
                tokens["reasoning"] = rt
    return tokens


def send_warmup(
    base: str,
    key: str,
    auth_index: str,
    account_id: str | None,
    model: str,
    timeout: float = 120.0,
) -> tuple[int | None, str, float, dict[str, int]]:
    headers = {
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "User-Agent": "codex_cli_rs/0.76.0 (session-warmup)",
        "OpenAI-Beta": "responses=experimental",
        "originator": "codex_cli_rs",
    }
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id
        headers["chatgpt-account-id"] = account_id

    t0 = time.time()
    resp = management_json(
        base,
        key,
        "/api-call",
        method="POST",
        payload={
            "authIndex": auth_index,
            "method": "POST",
            "url": CODEX_RESPONSES_URL,
            "header": headers,
            "data": json.dumps(build_warmup_payload(model)),
        },
        timeout=timeout,
    )
    elapsed = time.time() - t0
    status = as_int(resp.get("status_code"))
    body = resp.get("body")
    body_str = body if isinstance(body, str) else json.dumps(body) if body is not None else ""
    tokens = extract_usage_tokens(body_str)
    return status, body_str, elapsed, tokens


def session_elapsed_seconds(usage: UsageSnapshot) -> int | None:
    """How far into the 5h window the countdown has moved (None if unknown)."""
    if usage.session_reset is None:
        return None
    return max(0, SESSION_WINDOW_SECONDS - int(usage.session_reset))


def is_session_progressing(usage: UsageSnapshot, threshold: int = PROGRESS_THRESHOLD_SECONDS) -> bool:
    """True only if the 5h timer has actually counted down past `threshold` seconds.

    used_percent can be 1% while reset is still stuck at 18000 — that is NOT open.
    """
    elapsed = session_elapsed_seconds(usage)
    if elapsed is None:
        return False
    return elapsed >= threshold


def skip_reason(
    account: AuthAccount,
    usage: UsageSnapshot,
    *,
    force: bool,
    idle_max_used: int,
) -> str | None:
    if account.disabled:
        return "disabled"
    if usage.allowed is False:
        detail = usage.rate_limit_reached_type or "allowed=false"
        return f"not allowed ({detail})"
    if usage.limit_reached is True and not force:
        return "limit_reached"
    if force:
        return None

    # Primary gate: countdown progress, not used%.
    if is_session_progressing(usage):
        elapsed = session_elapsed_seconds(usage) or 0
        return (
            f"timer already running "
            f"(~{elapsed // 60}m into window, reset={usage.session_reset}s, used={usage.session_used}%)"
        )

    # Timer not progressing (reset missing / still ~full 5h) → needs warm even if used>0.
    return None


def process_account(
    base: str,
    key: str,
    account: AuthAccount,
    *,
    dry_run: bool,
    force: bool,
    idle_max_used: int,
    model: str,
    post_check_delay: float,
) -> WarmResult:
    try:
        before = fetch_usage(base, key, account.auth_index)
    except Exception as e:
        return WarmResult(
            account=account.account,
            auth_index=account.auth_index,
            action="failed",
            note=f"usage fetch failed: {e}",
        )

    reason = skip_reason(account, before, force=force, idle_max_used=idle_max_used)
    if reason:
        return WarmResult(
            account=account.account,
            auth_index=account.auth_index,
            action="skipped",
            note=reason,
            before=before,
            after=before,
        )

    if dry_run:
        return WarmResult(
            account=account.account,
            auth_index=account.auth_index,
            action="dry-run",
            note=f"would warm with {model}",
            before=before,
            after=before,
        )

    try:
        status, body, elapsed, tokens = send_warmup(
            base,
            key,
            account.auth_index,
            before.account_id,
            model,
        )
    except Exception as e:
        return WarmResult(
            account=account.account,
            auth_index=account.auth_index,
            action="failed",
            note=f"trigger failed: {e}",
            before=before,
        )

    if status is None or not (200 <= status < 300):
        snippet = body[:240].replace("\n", " ") if body else ""
        return WarmResult(
            account=account.account,
            auth_index=account.auth_index,
            action="failed",
            note=f"upstream HTTP {status}: {snippet}",
            before=before,
            status_code=status,
            elapsed_s=elapsed,
        )

    if post_check_delay > 0:
        time.sleep(post_check_delay)

    try:
        after = fetch_usage(base, key, account.auth_index)
    except Exception as e:
        return WarmResult(
            account=account.account,
            auth_index=account.auth_index,
            action="warmed",
            note=f"ok but post-check failed: {e}",
            before=before,
            status_code=status,
            elapsed_s=elapsed,
            tokens=tokens,
        )

    note_parts = []
    if tokens:
        note_parts.append(
            "tokens "
            + "/".join(f"{k}={v}" for k, v in tokens.items() if k in ("input", "output", "total", "reasoning"))
        )
    if after.session_reset is not None:
        note_parts.append(f"reset ~{_fmt_seconds(after.session_reset)}")
    du = None
    if before.session_used is not None and after.session_used is not None:
        du = after.session_used - before.session_used
        if du:
            note_parts.append(f"session Δ{du:+d}%")
    if before.weekly_used is not None and after.weekly_used is not None:
        dw = after.weekly_used - before.weekly_used
        if dw:
            note_parts.append(f"weekly Δ{dw:+d}%")
    if not note_parts:
        note_parts.append("ok (no integer % change)")

    return WarmResult(
        account=account.account,
        auth_index=account.auth_index,
        action="warmed",
        note="; ".join(note_parts),
        before=before,
        after=after,
        status_code=status,
        elapsed_s=elapsed,
        tokens=tokens,
    )


def _fmt_seconds(sec: int) -> str:
    sec = max(0, int(sec))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def print_table(results: list[WarmResult]) -> None:
    col_acc = max(len("account"), max((len(r.account) for r in results), default=7))
    col_sess = 14
    col_act = 8
    header = f"{'account':<{col_acc}}  {'session':<{col_sess}}  {'action':<{col_act}}  note"
    print(header)
    print("-" * len(header))
    for r in results:
        b = r.before.session_label() if r.before else "--"
        a = r.after.session_label() if r.after else "--"
        sess = f"{b}→{a}" if b != a else b
        print(f"{r.account:<{col_acc}}  {sess:<{col_sess}}  {r.action:<{col_act}}  {r.note}")

    counts = {"warmed": 0, "skipped": 0, "failed": 0, "dry-run": 0}
    for r in results:
        counts[r.action] = counts.get(r.action, 0) + 1
    print()
    print(
        f"Warmed {counts.get('warmed', 0)} / skipped {counts.get('skipped', 0)} / "
        f"failed {counts.get('failed', 0)} / dry-run {counts.get('dry-run', 0)}"
    )


def filter_accounts(accounts: list[AuthAccount], only: list[str] | None) -> list[AuthAccount]:
    if not only:
        return accounts
    needles = [x.strip().lower() for x in only if x.strip()]
    out = []
    for acc in accounts:
        hay = f"{acc.account} {acc.name} {acc.auth_index}".lower()
        if any(n in hay for n in needles):
            out.append(acc)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Warm Codex 5h session windows on all eligible CLIProxyAPI accounts.",
    )
    parser.add_argument("--base", help="Management API origin (default: GrandeBar prefs / env)")
    parser.add_argument("--key", help="Management key (default: GrandeBar prefs / env)")
    parser.add_argument("--dry-run", action="store_true", help="List targets without sending warmups")
    parser.add_argument("--yes", "-y", action="store_true", help="Skip interactive confirmation")
    parser.add_argument("--force", action="store_true", help="Warm even if session already open")
    parser.add_argument(
        "--idle-max-used",
        type=int,
        default=DEFAULT_IDLE_MAX_USED,
        help=f"Only warm if session used%% <= this (default {DEFAULT_IDLE_MAX_USED}; ignored with --force)",
    )
    parser.add_argument("--only", help="Comma-separated account email/name substrings")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"Model for warmup (default {DEFAULT_MODEL})")
    parser.add_argument(
        "--concurrency",
        type=int,
        default=DEFAULT_CONCURRENCY,
        help=f"Parallel warmups (default {DEFAULT_CONCURRENCY})",
    )
    parser.add_argument("--post-check-delay", type=float, default=2.0, help="Seconds to wait before post usage check")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero if any account failed")
    args = parser.parse_args(argv)

    base = resolve_base(args.base)
    key = resolve_key(args.key)
    only = [x.strip() for x in (args.only or "").split(",") if x.strip()] or None
    concurrency = max(1, min(6, args.concurrency))

    print(f"Base: {base}")
    print(f"Model: {args.model}")
    print(f"Mode: {'dry-run' if args.dry_run else 'live'} | force={args.force} | idle_max_used={args.idle_max_used}")
    print()

    try:
        accounts = list_auth_accounts(base, key)
    except Exception as e:
        print(f"Failed to list auth files: {e}", file=sys.stderr)
        return 2

    accounts = filter_accounts(accounts, only)
    if not accounts:
        print("No matching auth accounts.")
        return 1

    print(f"Auth accounts: {len(accounts)}")
    for a in accounts:
        flag = " (disabled)" if a.disabled else ""
        print(f"  - {a.account} [{a.auth_index[:8]}…]{flag}")
    print()

    if not args.dry_run and not args.yes:
        answer = input(f"Send minimal warmup to eligible accounts among {len(accounts)}? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print("Aborted.")
            return 130

    results: list[WarmResult] = []
    if concurrency == 1:
        for acc in accounts:
            results.append(
                process_account(
                    base,
                    key,
                    acc,
                    dry_run=args.dry_run,
                    force=args.force,
                    idle_max_used=args.idle_max_used,
                    model=args.model,
                    post_check_delay=args.post_check_delay,
                )
            )
    else:
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            futures = {
                pool.submit(
                    process_account,
                    base,
                    key,
                    acc,
                    dry_run=args.dry_run,
                    force=args.force,
                    idle_max_used=args.idle_max_used,
                    model=args.model,
                    post_check_delay=args.post_check_delay,
                ): acc
                for acc in accounts
            }
            for fut in as_completed(futures):
                results.append(fut.result())
        # stable order by original account list
        order = {a.auth_index: i for i, a in enumerate(accounts)}
        results.sort(key=lambda r: order.get(r.auth_index, 999))

    print_table(results)

    failed = sum(1 for r in results if r.action == "failed")
    if args.strict and failed:
        return 1
    if failed and not any(r.action == "warmed" for r in results) and not args.dry_run:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
