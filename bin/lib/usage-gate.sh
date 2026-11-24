# shellcheck shell=bash
# Shared usage gate for bin/farm.sh and bin/run-task.sh: should new work start, given the plan usage?
#   usage: source "$FARM/bin/lib/usage-gate.sh"; usage_gate [status key=value ...] || <over a limit>
# Also provides the pause helpers set_pause (never shortens a pause) and pause_time (message formatting).
# Needs $FARM set. Limits come from farm.conf / the environment (bin/lib/config.sh).

# shellcheck source=config.sh
source "$FARM/bin/lib/config.sh"

# Format a unix time for messages: "18:10" when it is less than 20 hours away, otherwise "Thu 21:00".
#   pause_time <unix-seconds>
pause_time() {
  if [ $(( $1 - $(date +%s) )) -lt 72000 ]; then date -d @"$1" '+%H:%M'; else date -d @"$1" '+%a %H:%M'; fi
}

# Print PAUSE_MINUTES when it is a whole number, otherwise the default 60 (so "abc" can't write NaN).
#   pause_minutes
pause_minutes() {
  if [[ "${PAUSE_MINUTES:-}" =~ ^[0-9]+$ ]]; then echo "$PAUSE_MINUTES"; else echo 60; fi
}

# Pause dispatching until <unix-seconds>, never shortening a longer pause already in state/paused-until.
# Prints the pause that is in effect afterwards (the new one, or the longer existing one).
#   set_pause <unix-seconds>
set_pause() {
  local current
  current="$(cat "$FARM/state/paused-until" 2>/dev/null || echo 0)"
  if [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -gt "$1" ]; then
    echo "$current"
  else
    mkdir -p "$FARM/state"
    echo "$1" > "$FARM/state/paused-until"
    echo "$1"
  fi
}

# Check the plan usage (bin/usage.sh: cached reading, probing only when stale) against the limits.
# Returns 0 when work may start: under every limit, or the check failed (a warning is printed; the
# usage-limit requeue in bin/run-task.sh stays the safety net). Returns 1 when a window is at or over its
# limit: state/paused-until is set to that window's reset (never shortened; an unknown reset time pauses
# for PAUSE_MINUTES, default 60), a message is printed, and a `usage_pause` status event is recorded with
# the extra key=value fields given as arguments. With several windows over their limits, the latest reset wins.
usage_gate() {
  local json verdict window percent limit until reset effective note=""
  farm_config "$FARM"
  [[ "${PAUSE_MINUTES:-}" =~ ^[0-9]+$ ]] || PAUSE_MINUTES=60
  if ! json="$("$FARM/bin/usage.sh" --json)"; then
    echo "WARNING: usage check failed; starting anyway" >&2
    return 0
  fi
  # Prints "<window> <percent> <limit> <until-unix> <known|unknown>" for the over-limit window that resets
  # last, or nothing. A window without a valid reset time pauses for the fallback (now + PAUSE_MINUTES).
  verdict="$(printf '%s' "$json" | node -e '
    const u = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const [lim5h, limWeek, fallbackMin] = process.argv.slice(1).map(Number);
    const now = Date.now() / 1000;
    const over = [["5h", u.five_hour, lim5h], ["week", u.seven_day, limWeek]].flatMap(([label, w, limit]) => {
      if (!(limit > 0) || !w || !(Number(w.percent) >= limit)) return [];
      const until = Math.floor(Date.parse(w.resets_at) / 1000);
      if (!Number.isFinite(until)) return [{ label, percent: Number(w.percent), limit, until: Math.floor(now + fallbackMin * 60), reset: "unknown" }];
      // A window that has already reset since the reading is no reason to wait
      return until > now ? [{ label, percent: Number(w.percent), limit, until, reset: "known" }] : [];
    }).sort((a, b) => b.until - a.until);
    if (over.length) { const o = over[0]; console.log(`${o.label} ${o.percent} ${o.limit} ${o.until} ${o.reset}`); }
  ' "$USAGE_LIMIT_5H" "$USAGE_LIMIT_WEEK" "$PAUSE_MINUTES")" \
    || { echo "WARNING: could not evaluate the usage reading; starting anyway" >&2; return 0; }
  [ -n "$verdict" ] || return 0

  read -r window percent limit until reset <<< "$verdict"
  effective="$(set_pause "$until")"
  [ "$reset" = unknown ] && note=" (reset time unknown)"
  [ "$effective" -gt "$until" ] && note="$note (an existing longer pause is kept)"
  echo "usage $window ${percent}% ≥ ${limit}%: not starting tasks until $(pause_time "$effective")$note"
  node "$FARM/bin/status.js" usage_pause window="$window" percent="$percent" limit="$limit" \
    until="$(date -u -d @"$effective" +%Y-%m-%dT%H:%M:%SZ)" reset="$reset" "$@" || true
  return 1
}
