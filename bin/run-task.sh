#!/usr/bin/env bash
# Run ONE coding task autonomously against a git repo.
#   usage: bin/run-task.sh <repo-path> <task-file.md>
# Settings (environment variables):
#   MODEL=sonnet            model for orchestrator + subagents (sonnet is lighter on Pro limits; opus is stronger)
#   TIMEOUT=3600            max seconds per task
#   PERMISSION_MODE=auto    auto | acceptEdits | bypassPermissions (bypass only inside a container!)
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 2; }

[ $# -eq 2 ] || die "usage: $0 <repo-path> <task-file.md>"
REPO="$(realpath "$1")"; TASK="$(realpath "$2")"
MODEL="${MODEL:-sonnet}"; TIMEOUT="${TIMEOUT:-3600}"; PERM="${PERMISSION_MODE:-auto}"

[ -f "$TASK" ] || die "task file not found: $TASK"
git -C "$REPO" rev-parse --verify -q HEAD >/dev/null || die "$REPO is not a git repo with at least one commit"
claude auth status 2>/dev/null | grep -q '"loggedIn": true' \
  || die "Claude CLI is not logged in. Run 'claude' then '/login' in a terminal."

NAME="$(basename "$TASK" .md)"
ID="$(date +%Y%m%d-%H%M%S)-$NAME"
BRANCH="agent/$ID"
WT="$FARM/worktrees/$ID"
LOG="$FARM/logs/$ID"

# Skills are per project: agents see only what is committed in <repo>/.claude/skills
if [ -n "$(git -C "$REPO" status --porcelain -- .claude/skills .claude/skills.lock.json 2>/dev/null)" ]; then
  echo "WARNING: $REPO has uncommitted changes in .claude/skills; agents will NOT see them (commit first)" >&2
fi

# Isolated worktree + branch per task, so parallel agents never collide
BASE="$(git -C "$REPO" rev-parse --short HEAD)"
git -C "$REPO" worktree add -q -b "$BRANCH" "$WT"
node "$FARM/bin/build-agents.js" "$FARM/agents" > "$LOG.agents.json"
cp "$TASK" "$LOG.task.md"

echo "[$ID] started  repo=$REPO branch=$BRANCH model=$MODEL"
set +e
( cd "$WT" && timeout "$TIMEOUT" claude -p "$(cat "$TASK")" \
    --append-system-prompt-file "$FARM/prompts/orchestrator.md" \
    --agents "$LOG.agents.json" \
    --permission-mode "$PERM" \
    --model "$MODEL" \
    $( [ -d "$HOME/skills" ] && printf -- '--add-dir %s' "$HOME/skills" ) \
    --output-format json < /dev/null ) > "$LOG.json" 2> "$LOG.err"
RC=$?
set -e

# Pull the orchestrator's final report out of the JSON result
node -e '
  const fs = require("fs");
  let r = {};
  try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
  fs.writeFileSync(process.argv[2], (r.result || "STATUS: FAILED\n\nNo result (crash, timeout or usage limit). See .err log.") + "\n");
' "$LOG.json" "$LOG.report.md"

if [ $RC -eq 0 ] && head -1 "$LOG.report.md" | grep -q "STATUS: SUCCESS"; then
  STATUS=done
else
  STATUS=failed
  [ $RC -eq 124 ] && echo "(timed out after ${TIMEOUT}s)" >> "$LOG.report.md"
fi

# Move the task out of tasks/running if it came from the queue
case "$TASK" in "$FARM/tasks/running/"*) mv "$TASK" "$FARM/tasks/$STATUS/$ID.md" ;; esac

echo "[$ID] $STATUS  report=$LOG.report.md"
echo "        review:  git -C $REPO log --stat $BASE..$BRANCH   (or open $WT)"
[ "$STATUS" = done ]
