#!/usr/bin/env bash
# Dispatcher: run every task in tasks/inbox/, across any number of projects, N agents at a time.
#   usage: bin/farm.sh [parallel=2]
# Each task names its repo in its frontmatter (`repo: ~/code/app`). Safe to run from cron:
# only one dispatcher runs at a time, and it waits out a usage-limit pause.
# Keep parallelism low on a Pro plan: all agents share the same usage limits.
# Before dispatching it checks the plan usage (bin/usage.sh) against farm.conf's limits and, when a window is
# at or over its limit, pauses until that window resets instead (see README: "Usage limits").
#
# Settings (environment variables; the usage limits also live in farm.conf):
#   PARALLEL=2              tasks at a time (the first argument wins)
#   USAGE_LIMIT_5H=75       don't start tasks at or above this 5-hour usage percentage (0 = off)
#   USAGE_LIMIT_WEEK=90     don't start tasks at or above this weekly usage percentage (0 = off)
#   USAGE_GATE=1            0 skips the usage check here and in bin/run-task.sh
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
PARALLEL="${1:-${PARALLEL:-2}}"
mkdir -p "$FARM/state" "$FARM/tasks"/{inbox,running,done,failed}

exec 9>"$FARM/.farm.lock"
flock -n 9 || { echo "dispatcher already running"; exit 0; }

# Respect a usage-limit pause set by run-task.sh
if [ -f "$FARM/state/paused-until" ] && [ "$(date +%s)" -lt "$(cat "$FARM/state/paused-until")" ]; then
  echo "paused (usage limit) until $(date -d @"$(cat "$FARM/state/paused-until")" '+%H:%M')"; exit 0
fi
rm -f "$FARM/state/paused-until"

shopt -s nullglob
queued=("$FARM"/tasks/inbox/*.md)
[ ${#queued[@]} -gt 0 ] || { echo "inbox empty"; exit 0; }

# Don't start a batch when a plan-usage window is at or over its limit (a failed check only warns)
if [ "${USAGE_GATE:-1}" != 0 ]; then
  # shellcheck source=lib/usage-gate.sh
  source "$FARM/bin/lib/usage-gate.sh"
  usage_gate || exit 0
fi

running=()
for t in "${queued[@]}"; do
  repo="$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f&&/^repo:/{sub(/^repo:[ ]*/,"");print;exit}' "$t")"
  if [ -z "$repo" ]; then
    echo "skip $(basename "$t"): no 'repo:' in frontmatter"; continue
  fi
  mv "$t" "$FARM/tasks/running/"
  running+=("$FARM/tasks/running/$(basename "$t")")
done
[ ${#running[@]} -gt 0 ] || exit 0

echo "dispatching ${#running[@]} task(s), $PARALLEL at a time"
printf '%s\0' "${running[@]}" | xargs -0 -P "$PARALLEL" -I{} "$FARM/bin/run-task.sh" {} || true
node "$FARM/bin/status.js" show
