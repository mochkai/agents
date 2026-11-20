#!/usr/bin/env bash
# Process every task in tasks/inbox/ against one repo, N agents in parallel.
#   usage: bin/farm.sh <repo-path> [parallel=2]
# Keep parallelism low on a Pro plan: all agents share the same usage limits.
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${1:?usage: $0 <repo-path> [parallel]}"
PARALLEL="${2:-2}"

# Only one farm run at a time (safe to call from cron)
exec 9>"$FARM/.farm.lock"
flock -n 9 || { echo "farm already running"; exit 0; }

shopt -s nullglob
queued=("$FARM"/tasks/inbox/*.md)
[ ${#queued[@]} -gt 0 ] || { echo "inbox empty"; exit 0; }

running=()
for t in "${queued[@]}"; do
  mv "$t" "$FARM/tasks/running/"
  running+=("$FARM/tasks/running/$(basename "$t")")
done

echo "dispatching ${#running[@]} task(s), $PARALLEL at a time"
printf '%s\0' "${running[@]}" | xargs -0 -P "$PARALLEL" -I{} "$FARM/bin/run-task.sh" "$REPO" {} || true
echo "done: $(ls "$FARM"/tasks/done | wc -l) succeeded total, $(ls "$FARM"/tasks/failed | wc -l) failed total"
