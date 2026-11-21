#!/usr/bin/env bash
# Live view of the agent farm, refreshed every N seconds (default 5). Ctrl+C to exit.
#   usage: bin/watch.sh [seconds]
FARM="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${1:-5}"
trap 'tput cnorm 2>/dev/null; echo; exit 0' INT TERM
tput civis 2>/dev/null
while true; do
  frame="$(node "$FARM/bin/watch.js")"
  clear
  printf '%s\n\n\033[2mrefreshing every %ss · Ctrl+C to exit\033[0m\n' "$frame" "$INTERVAL"
  sleep "$INTERVAL"
done
