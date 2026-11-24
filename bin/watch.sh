#!/usr/bin/env bash
# Live view of the agent farm, refreshed every N seconds (default 5). Ctrl+C to exit.
#   usage: bin/watch.sh [seconds]
# Environment:
#   WATCH_USAGE_REFRESH=600   seconds between background plan-usage refreshes (bin/usage.sh --refresh,
#                             a tiny amount of quota each); 0 disables them. The monitor itself only reads
#                             state/usage.json, so frames cost nothing.
FARM="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${1:-5}"
USAGE_REFRESH="${WATCH_USAGE_REFRESH:-600}"
[[ "$USAGE_REFRESH" =~ ^[0-9]+$ ]] || USAGE_REFRESH=600
trap 'tput cnorm 2>/dev/null; echo; exit 0' INT TERM
tput civis 2>/dev/null

# Start a quiet background usage refresh when the last reading is older than USAGE_REFRESH seconds
# and the previous refresh has finished (never two at once, never blocking a frame).
refresh_pid=""
maybe_refresh_usage() {
  [ "$USAGE_REFRESH" -gt 0 ] || return 0
  [ -n "$refresh_pid" ] && kill -0 "$refresh_pid" 2>/dev/null && return 0
  local last
  last="$(stat -c %Y "$FARM/state/usage.json" 2>/dev/null || echo 0)"
  # A failed refresh leaves the file untouched, so also wait USAGE_REFRESH after each attempt
  [ -n "${last_attempt:-}" ] && [ "$last_attempt" -gt "$last" ] && last="$last_attempt"
  [ $(( $(date +%s) - last )) -ge "$USAGE_REFRESH" ] || return 0
  last_attempt="$(date +%s)"
  "$FARM/bin/usage.sh" --refresh >/dev/null 2>&1 < /dev/null &
  refresh_pid=$!
}

while true; do
  maybe_refresh_usage
  frame="$(node "$FARM/bin/watch.js")"
  clear
  printf '%s\n\n\033[2mrefreshing every %ss · Ctrl+C to exit\033[0m\n' "$frame" "$INTERVAL"
  sleep "$INTERVAL"
done
