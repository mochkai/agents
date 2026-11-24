#!/usr/bin/env bash
# Claude plan usage (5-hour and weekly windows), cached in state/usage.json.
#   usage: bin/usage.sh [--refresh] [--json]
# Without --refresh, a reading younger than USAGE_MAX_AGE seconds is reused. Otherwise it probes the CLI with
# a one-turn Haiku call (`claude -p ok --model haiku --tools "" --output-format stream-json --verbose`), takes
# the last `rate_limit_event`, and writes state/usage.json atomically:
#   {checked_at, five_hour: {percent, resets_at, status}, seven_day: {percent, resets_at, status}}
# A probe costs a tiny amount of quota, and the windows are shared with your own interactive sessions.
# Prints a one-line summary (`5h 42% (resets 18:10) · week 25% (resets Thu 21:00)`), or the JSON with --json.
# Each probe records a `usage` status event (bin/status.js). Probes never overlap (state/.usage.lock).
#
# Settings (farm.conf, overridden by environment variables):
#   USAGE_MAX_AGE=600          seconds a cached reading is reused
# Environment:
#   USAGE_PROBE_TIMEOUT=120    max seconds for the probe
#
# Exit codes: 0 ok, 1 no reading (probe failed or no rate_limit_event: not logged in, offline; the old file
# is kept), 2 bad input
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 2; }
status() { node "$FARM/bin/status.js" "$@" || true; }
# shellcheck source=lib/config.sh
source "$FARM/bin/lib/config.sh"
farm_config "$FARM"

REFRESH=0; JSON=0
for arg in "$@"; do
  case "$arg" in
    --refresh) REFRESH=1 ;;
    --json) JSON=1 ;;
    *) die "usage: $0 [--refresh] [--json]" ;;
  esac
done

STATE="$FARM/state"; FILE="$STATE/usage.json"
mkdir -p "$STATE"

# True if state/usage.json exists and is younger than USAGE_MAX_AGE seconds.
fresh() {
  [ -f "$FILE" ] && [ $(( $(date +%s) - $(stat -c %Y "$FILE") )) -lt "$USAGE_MAX_AGE" ]
}

# Print state/usage.json as the one-line summary, or as JSON with --json. Fails if the file is unreadable.
show() {
  node -e '
    const fs = require("fs");
    const [file, json] = process.argv.slice(1);
    const u = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!u || typeof u !== "object" || (!u.five_hour && !u.seven_day)) process.exit(1);
    if (json === "1") { process.stdout.write(JSON.stringify(u, null, 2) + "\n"); process.exit(0); }
    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const pad = (n) => String(n).padStart(2, "0");
    // Resets within 20 hours show the time only, later ones the weekday too
    const when = (iso) => {
      const d = new Date(iso);
      if (!iso || isNaN(d)) return "?";
      const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
      return d - Date.now() < 20 * 3600e3 ? hm : `${days[d.getDay()]} ${hm}`;
    };
    const part = (label, w) => (w ? `${label} ${w.percent}% (resets ${when(w.resets_at)})` : `${label} ?`);
    console.log(`${part("5h", u.five_hour)} · ${part("week", u.seven_day)}`);
  ' "$FILE" "$JSON"
}

# Probe the CLI once and write state/usage.json atomically. Returns 1 (old file kept) when no usable
# rate_limit_event came back.
probe() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  # Run from an empty directory so no project CLAUDE.md or settings are loaded; no tools, no saved session.
  # A failed run can still carry the event (e.g. when the limit is already reached), so the exit code is
  # only reported, and the output is parsed either way.
  ( cd "$tmp" && timeout "${USAGE_PROBE_TIMEOUT:-120}" claude -p ok --model haiku --tools "" \
      --no-session-persistence --output-format stream-json --verbose < /dev/null ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  if ! node -e '
    const fs = require("fs");
    const [src, dst] = process.argv.slice(1);
    let info = null;
    // The last rate_limit_event wins; partial or non-JSON lines are skipped
    for (const line of fs.readFileSync(src, "utf8").split("\n")) {
      try { const v = JSON.parse(line); if (v && v.type === "rate_limit_event" && v.rate_limit_info) info = v.rate_limit_info; } catch {}
    }
    if (!info) process.exit(1);
    const win = (w) => {
      if (!w || !Number.isFinite(Number(w.utilization))) return null;
      const reset = Number(w.resetsAt);
      return {
        percent: Math.round(Number(w.utilization) * 100),
        resets_at: reset > 0 ? new Date(reset * 1000).toISOString() : null,
        status: String(w.status || "unknown"),
      };
    };
    const u = info.unifiedWindows || {};
    // Older event shapes only describe one window at the top level
    const top = (type) => (info.rateLimitType === type ? info : null);
    const out = { checked_at: new Date().toISOString(), five_hour: win(u.five_hour || top("five_hour")), seven_day: win(u.seven_day || top("seven_day")) };
    if (!out.five_hour && !out.seven_day) process.exit(1);
    fs.writeFileSync(dst, JSON.stringify(out, null, 2) + "\n");
  ' "$tmp/out" "$FILE.tmp.$$"; then
    echo "WARNING: could not read plan usage (claude exit $rc; not logged in or offline?): $(head -c 300 "$tmp/err" | tr '\n' ' ')" >&2
    rm -rf "$tmp" "$FILE.tmp.$$"
    return 1
  fi
  mv "$FILE.tmp.$$" "$FILE"
  rm -rf "$tmp"
  status usage $(node -e '
    const u = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(`five_hour=${u.five_hour?.percent ?? ""} seven_day=${u.seven_day?.percent ?? ""} five_hour_resets_at=${u.five_hour?.resets_at ?? ""} seven_day_resets_at=${u.seven_day?.resets_at ?? ""}`);
  ' "$FILE")
}

if [ "$REFRESH" = 1 ] || ! fresh || ! show >/dev/null 2>&1; then
  started="$(date +%s)"
  exec 8>"$STATE/.usage.lock"
  flock -w 300 8 || { echo "WARNING: another usage probe is still running" >&2; exit 1; }
  # Someone else may have probed while we waited for the lock: reuse their reading
  if [ -f "$FILE" ] && { [ "$(stat -c %Y "$FILE")" -ge "$started" ] || { [ "$REFRESH" = 0 ] && fresh; }; } \
     && show >/dev/null 2>&1; then
    :
  else
    probe || exit 1
  fi
fi
show || { echo "WARNING: $FILE is unreadable" >&2; exit 1; }
