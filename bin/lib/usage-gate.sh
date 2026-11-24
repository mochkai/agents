# shellcheck shell=bash
# Shared usage gate for bin/farm.sh and bin/run-task.sh: should new work start, given the plan usage?
#   usage: source "$FARM/bin/lib/usage-gate.sh"; usage_gate [status key=value ...] || <over a limit>
# Needs $FARM set. Limits come from farm.conf / the environment (bin/lib/config.sh).

# shellcheck source=config.sh
source "$FARM/bin/lib/config.sh"

# Check the plan usage (bin/usage.sh: cached reading, probing only when stale) against the limits.
# Returns 0 when work may start: under every limit, or the check failed (a warning is printed; the
# usage-limit requeue in bin/run-task.sh stays the safety net). Returns 1 when a window is at or over its
# limit: state/paused-until is set to that window's reset (never shortened), a message is printed, and a
# `usage_pause` status event is recorded with the extra key=value fields given as arguments.
# When several windows are over their limits, the pause lasts until the latest reset.
usage_gate() {
  local json verdict window percent limit until current when
  farm_config "$FARM"
  if ! json="$("$FARM/bin/usage.sh" --json)"; then
    echo "WARNING: usage check failed; starting anyway" >&2
    return 0
  fi
  # Prints "<window> <percent> <limit> <until-unix>" for the over-limit window that resets last, or nothing
  verdict="$(printf '%s' "$json" | node -e '
    const u = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const [lim5h, limWeek] = process.argv.slice(1).map(Number);
    const now = Date.now() / 1000;
    const over = [["5h", u.five_hour, lim5h], ["week", u.seven_day, limWeek]].flatMap(([label, w, limit]) => {
      if (!(limit > 0) || !w || !(Number(w.percent) >= limit)) return [];
      const until = Math.floor(Date.parse(w.resets_at) / 1000);
      // A window that has already reset since the reading is no reason to wait
      return until > now ? [{ label, percent: Number(w.percent), limit, until }] : [];
    }).sort((a, b) => b.until - a.until);
    if (over.length) console.log(`${over[0].label} ${over[0].percent} ${over[0].limit} ${over[0].until}`);
  ' "$USAGE_LIMIT_5H" "$USAGE_LIMIT_WEEK")" || { echo "WARNING: could not evaluate the usage reading; starting anyway" >&2; return 0; }
  [ -n "$verdict" ] || return 0

  read -r window percent limit until <<< "$verdict"
  # Keep a longer pause that is already set (e.g. by a usage-limit requeue)
  current="$(cat "$FARM/state/paused-until" 2>/dev/null || echo 0)"
  [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -gt "$until" ] || echo "$until" > "$FARM/state/paused-until"
  # Pauses longer than 20 hours name the weekday too
  if [ $(( until - $(date +%s) )) -lt 72000 ]; then when="$(date -d @"$until" '+%H:%M')"; else when="$(date -d @"$until" '+%a %H:%M')"; fi
  echo "usage $window ${percent}% ≥ ${limit}%: not starting tasks until $when"
  node "$FARM/bin/status.js" usage_pause window="$window" percent="$percent" limit="$limit" \
    until="$(date -u -d @"$until" +%Y-%m-%dT%H:%M:%SZ)" "$@" || true
  return 1
}
