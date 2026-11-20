#!/usr/bin/env bash
# Run ONE coding task autonomously, then open a PR if it passed tests and review.
#   usage: bin/run-task.sh <task-file.md> [repo-path]
# The repo comes from the task's frontmatter (`repo: ~/code/app`) unless it is given as an argument.
#
# Settings (environment variables):
#   MODEL=sonnet            model for the orchestrator and subagents (docs-writer always uses haiku)
#   TIMEOUT=3600            max seconds per task
#   PERMISSION_MODE=auto    auto | acceptEdits | bypassPermissions (bypass only inside a container!)
#   PR=1                    push the branch and open a GitHub PR on success (0 = keep the local branch only)
#   STATUS_HOOK=<cmd>       command run with each status event as JSON on stdin (see bin/status.js)
#
# Exit codes: 0 done, 1 failed, 3 requeued (usage limit hit), 2 bad input
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 2; }
status() { node "$FARM/bin/status.js" "$@" || true; }
# Read a frontmatter field from the task file
fm() { awk -v k="$1" 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f&&index($0,k":")==1{sub("^"k":[ ]*","");print;exit}' "$TASK"; }

[ $# -ge 1 ] || die "usage: $0 <task-file.md> [repo-path]"
TASK="$(realpath "$1")"
[ -f "$TASK" ] || die "task file not found: $TASK"
REPO_RAW="${2:-$(fm repo)}"
[ -n "$REPO_RAW" ] || die "no repo: add 'repo: /path/to/repo' to the task's frontmatter"
REPO="$(realpath "${REPO_RAW/#\~/$HOME}")"
MODEL="${MODEL:-sonnet}"; TIMEOUT="${TIMEOUT:-3600}"; PERM="${PERMISSION_MODE:-auto}"; PR="${PR:-1}"

git -C "$REPO" rev-parse --verify -q HEAD >/dev/null || die "$REPO is not a git repo with at least one commit"
claude auth status 2>/dev/null | grep -q '"loggedIn": true' \
  || die "Claude CLI is not logged in. Run 'claude' then '/login' in a terminal."

NAME="$(basename "$TASK" .md)"
TITLE="$(fm title)"; TITLE="${TITLE:-$NAME}"
ID="$(date +%Y%m%d-%H%M%S)-$NAME"
BRANCH="agent/$ID"
WT="$FARM/worktrees/$ID"
LOG="$FARM/logs/$ID"
mkdir -p "$FARM/logs" "$FARM/worktrees" "$FARM/state"

if [ -n "$(git -C "$REPO" status --porcelain -- .claude/skills 2>/dev/null)" ]; then
  echo "WARNING: $REPO has uncommitted changes in .claude/skills; agents will NOT see them (commit first)" >&2
fi

# Isolated worktree + branch per task, so parallel agents never collide
BASE="$(git -C "$REPO" rev-parse --short HEAD)"
BASE_BRANCH="$(git -C "$REPO" symbolic-ref --quiet --short HEAD || echo main)"
git -C "$REPO" worktree add -q -b "$BRANCH" "$WT"
node "$FARM/bin/build-agents.js" "$FARM/agents" > "$LOG.agents.json"
node "$FARM/bin/build-agents.js" --body "$FARM/agents/orchestrator.md" > "$LOG.orchestrator.md"
cp "$TASK" "$LOG.task.md"

status started id="$ID" repo="$REPO" branch="$BRANCH" title="$TITLE" model="$MODEL" pid="$$"
echo "[$ID] started  repo=$REPO branch=$BRANCH model=$MODEL"

ADD_DIR=(); [ -d "$HOME/skills" ] && ADD_DIR=(--add-dir "$HOME/skills")
set +e
( cd "$WT" && timeout "$TIMEOUT" claude -p "$(printf 'MODE: unattended\n\n'; cat "$TASK")" \
    --append-system-prompt-file "$LOG.orchestrator.md" \
    --agents "$LOG.agents.json" \
    --permission-mode "$PERM" \
    --model "$MODEL" \
    "${ADD_DIR[@]}" \
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

# Hit the Pro usage limit? Put the task back in the queue and pause dispatching for a while.
if [ $RC -ne 0 ] && grep -qiE 'usage limit|rate.?limit|limit reached|hit your limit|overloaded' "$LOG.err" "$LOG.report.md" 2>/dev/null; then
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 || true
  case "$TASK" in "$FARM/tasks/running/"*) mv "$TASK" "$FARM/tasks/inbox/" ;; esac
  date -d "+${PAUSE_MINUTES:-60} minutes" +%s > "$FARM/state/paused-until"
  status requeued id="$ID" reason="usage limit"
  echo "[$ID] requeued: usage limit reached; dispatching paused for ${PAUSE_MINUTES:-60} minutes"
  exit 3
fi

if [ $RC -eq 0 ] && head -1 "$LOG.report.md" | grep -q "STATUS: SUCCESS"; then
  STATUS=done
else
  STATUS=failed
  [ $RC -eq 124 ] && echo "(timed out after ${TIMEOUT}s)" >> "$LOG.report.md"
fi

# Open a PR (success only, GitHub remotes only). Agents never push; this script does.
PR_URL=""
if [ "$STATUS" = done ] && [ "$PR" = 1 ]; then
  if git -C "$REPO" remote get-url origin 2>/dev/null | grep -q 'github.com'; then
    { tail -n +2 "$LOG.report.md"
      printf '\n---\nTask: `%s` · Branch: `%s`\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' "$NAME" "$BRANCH"
    } > "$LOG.pr.md"
    if git -C "$REPO" push -q -u origin "$BRANCH" 2>>"$LOG.err" \
       && PR_URL="$(cd "$REPO" && gh pr create --head "$BRANCH" --base "$BASE_BRANCH" --title "$TITLE" --body-file "$LOG.pr.md" 2>>"$LOG.err" | tail -1)"; then
      echo "[$ID] PR opened: $PR_URL"
    else
      echo "[$ID] WARNING: could not open a PR (see $LOG.err); the branch is still local" >&2
      PR_URL=""
    fi
  else
    echo "[$ID] no GitHub remote: skipping PR, work is on local branch $BRANCH"
  fi
fi

# Move the task out of tasks/running if it came from the queue
case "$TASK" in "$FARM/tasks/running/"*) mv "$TASK" "$FARM/tasks/$STATUS/$ID.md" ;; esac
status "$STATUS" id="$ID" pr="$PR_URL" report="$LOG.report.md"

echo "[$ID] $STATUS  report=$LOG.report.md"
[ -z "$PR_URL" ] && echo "        review:  git -C $REPO log --stat $BASE..$BRANCH   (or open $WT)"
[ "$STATUS" = done ]
