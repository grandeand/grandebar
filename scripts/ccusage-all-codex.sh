#!/usr/bin/env bash
# Aggregate ccusage across default ~/.codex and isolated multi-profile CODEX_HOME dirs
# (codex-grande, codex-aof, codex-main, …).
set -euo pipefail

SPEED="${CCUSAGE_SPEED:-fast}"
SINCE="${CCUSAGE_SINCE:-}"
TZ_NAME="${CCUSAGE_TZ:-$(date +%Z 2>/dev/null || echo Europe/Istanbul)}"
# Prefer IANA if available
if command -v python3 >/dev/null 2>&1; then
  TZ_NAME="$(python3 -c 'import time; print(time.tzname[0])' 2>/dev/null || echo Europe/Istanbul)"
fi
# Use Europe/Istanbul as stable default for TR machines
TZ_NAME="${CCUSAGE_TZ:-Europe/Istanbul}"

CCUSAGE_BIN="${CCUSAGE_BIN:-}"
if [[ -z "$CCUSAGE_BIN" ]]; then
  for c in "$HOME/.npm-global/bin/ccusage" /opt/homebrew/bin/ccusage /usr/local/bin/ccusage; do
    if [[ -x "$c" ]]; then CCUSAGE_BIN="$c"; break; fi
  done
fi
if [[ -z "${CCUSAGE_BIN}" ]]; then
  echo "ccusage not found" >&2
  exit 1
fi

CONFIG_ARGS=()
for cfg in \
  "$(dirname "$0")/../Resources/ccusage.json" \
  "$HOME/.config/ccusage/ccusage.json"
 do
  if [[ -f "$cfg" ]]; then
    CONFIG_ARGS=(--config "$cfg")
    break
  fi
done

homes=()
add_home() {
  local p
  p="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  [[ -d "$p/sessions" || -f "$p/config.toml" ]] || return 0
  for existing in "${homes[@]+"${homes[@]}"}"; do
    [[ "$existing" == "$p" ]] && return 0
  done
  homes+=("$p")
}

add_home "$HOME/.codex"
for root in "$HOME/m365bridge-next/codex-cli" "$HOME/m365bridge-accounts/codex-cli"; do
  [[ -d "$root" ]] || continue
  for d in "$root"/*; do
    [[ -d "$d" ]] && add_home "$d"
  done
done

if [[ ${#homes[@]} -eq 0 ]]; then
  echo "No Codex homes found" >&2
  exit 1
fi

ARGS=(codex daily --json --offline --speed "$SPEED" --timezone "$TZ_NAME")
[[ -n "$SINCE" ]] && ARGS+=(--since "$SINCE")
ARGS+=("${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}")

python3 - "$CCUSAGE_BIN" "$SPEED" "${homes[@]}" -- "${ARGS[@]}" <<'PY'
import json, os, subprocess, sys
from collections import defaultdict

bin_path = sys.argv[1]
speed = sys.argv[2]
# homes until --
args = sys.argv[3:]
sep = args.index("--")
homes = args[:sep]
cc_args = args[sep + 1 :]

by_date = defaultdict(lambda: {
    "costUSD": 0.0,
    "inputTokens": 0,
    "outputTokens": 0,
    "cacheReadTokens": 0,
    "reasoningOutputTokens": 0,
    "totalTokens": 0,
    "models": set(),
    "homes": set(),
})
home_totals = []

for home in homes:
    env = os.environ.copy()
    env["CODEX_HOME"] = home
    try:
        out = subprocess.check_output([bin_path, *cc_args], env=env, stderr=subprocess.DEVNULL)
        data = json.loads(out)
    except Exception as e:
        home_totals.append({"home": home, "ok": False, "error": str(e), "costUSD": 0})
        continue
    cost = float((data.get("totals") or {}).get("costUSD") or 0)
    home_totals.append({"home": home, "ok": True, "costUSD": cost, "days": len(data.get("daily") or [])})
    for row in data.get("daily") or []:
        date = row.get("date")
        if not date:
            continue
        b = by_date[date]
        b["costUSD"] += float(row.get("costUSD") or 0)
        for k in ("inputTokens", "outputTokens", "cacheReadTokens", "reasoningOutputTokens", "totalTokens"):
            b[k] += int(row.get(k) or 0)
        models = row.get("models") or {}
        if isinstance(models, dict):
            b["models"].update(models.keys())
        b["homes"].add(os.path.basename(home.rstrip("/")) or home)

daily = []
for date in sorted(by_date):
    b = by_date[date]
    daily.append({
        "date": date,
        "costUSD": b["costUSD"],
        "inputTokens": b["inputTokens"],
        "outputTokens": b["outputTokens"],
        "cacheReadTokens": b["cacheReadTokens"],
        "reasoningOutputTokens": b["reasoningOutputTokens"],
        "totalTokens": b["totalTokens"],
        "models": sorted(b["models"]),
        "homes": sorted(b["homes"]),
    })

totals = {
    "costUSD": sum(r["costUSD"] for r in daily),
    "inputTokens": sum(r["inputTokens"] for r in daily),
    "outputTokens": sum(r["outputTokens"] for r in daily),
    "cacheReadTokens": sum(r["cacheReadTokens"] for r in daily),
    "reasoningOutputTokens": sum(r["reasoningOutputTokens"] for r in daily),
    "totalTokens": sum(r["totalTokens"] for r in daily),
}

print(json.dumps({
    "speed": speed,
    "homes": homes,
    "home_totals": home_totals,
    "daily": daily,
    "totals": totals,
}, indent=2, ensure_ascii=False))
PY
