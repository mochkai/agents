#!/usr/bin/env bash
# Run ONE coding task autonomously, then open a PR for human review: a normal PR if it passed tests and
# review, a draft `[WIP] <title>` PR if it failed (or timed out) but left commits on its branch.
#   usage: bin/run-task.sh <task-file.md> [repo-path]
# NEVER MERGES: this script only pushes the task's own branch and opens or updates a PR; a human merges.
# (The only merge here is `merge --ff-only origin/$BRANCH` on the agent's own branch in a fix round.)
# A new PR whose base is not the repo's default branch is stacked: bin/pr-stack-label.sh prepends a merge
# hint to its description and adds the `stacked` label, on it and on its parent (a failure there only warns).
# The repo comes from the task's frontmatter (`repo: ~/code/app`) unless it is given as an argument.
# Fix rounds (queued by bin/pm.sh) add `branch:`, `pr:`, `round:` and `base_branch:` to the frontmatter:
# the run then continues that branch (reusing its worktree when there is one) and updates the existing PR.
# A fix round is refused before any work (task -> tasks/failed/ with a note, exit 2) when the branch is
# not a farm `agent/*` branch, the PR is no longer open, the worktree has uncommitted changes, or the local
# branch cannot fast-forward to origin. All but the closed-PR case send a `needs_human` notification, and so
# does a fix round that fails or cannot push.
#
# Settings (environment variables):
#   MODEL=sonnet            model for the orchestrator and subagents (docs-writer always uses haiku)
#   TIMEOUT=3600            max seconds per task
#   PERMISSION_MODE=auto    auto | acceptEdits | bypassPermissions (bypass only inside a container!)
#   PR=1                    push the branch and open a GitHub PR (draft if failed; 0 = keep the local branch only)
#   PM=1                    after a PR is opened or updated, run the project manager (bin/pm.sh; 0 = skip)
#   STATUS_HOOK=<cmd>       command run with each status event as JSON on stdin (see bin/status.js)
#   USAGE_GATE=1            check the plan usage (bin/usage.sh) before any work; 0 skips the check
#   USAGE_LIMIT_5H=75 / USAGE_LIMIT_WEEK=90   usage limits in percent (also in farm.conf; 0 = off)
# Usage gate: when a usage window is at or over its limit, the task goes back to tasks/inbox/ (if it came
# from tasks/running/), dispatching pauses until that window resets, and it exits 3 before creating a worktree.
#
# Exit codes: 0 done, 1 failed, 3 requeued (usage limit hit, or a usage window over its limit), 2 bad input
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd -P)"   # physical path, so worktree paths from git compare equal
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
LOG="$FARM/logs/$ID"

# Usage gate: with several tasks in a batch, usage can cross a limit mid-batch. Checked before any worktree
# exists, so there is nothing to undo; the cached reading is reused and only refreshed when stale.
if [ "${USAGE_GATE:-1}" != 0 ]; then
  # shellcheck source=lib/usage-gate.sh
  source "$FARM/bin/lib/usage-gate.sh"
  mkdir -p "$FARM/state"
  if ! usage_gate task="$NAME"; then
    case "$TASK" in "$FARM/tasks/running/"*) mkdir -p "$FARM/tasks/inbox"; mv "$TASK" "$FARM/tasks/inbox/" ;; esac
    echo "[$ID] requeued: plan usage over its limit"
    exit 3
  fi
fi
# Fix rounds continue an existing branch and PR
FIX_BRANCH="$(fm branch)"; EXISTING_PR="$(fm pr)"; ROUND="$(fm round)"; [[ "$ROUND" =~ ^[0-9]+$ ]] || ROUND=0
if [ -n "$FIX_BRANCH" ]; then
  # The farm only continues its own branches
  case "$FIX_BRANCH" in agent/?*) ;; *) die "branch '$FIX_BRANCH' is not a farm branch (must start with agent/)" ;; esac
  git check-ref-format --branch "$FIX_BRANCH" >/dev/null 2>&1 || die "invalid branch name: $FIX_BRANCH"
fi
BRANCH="${FIX_BRANCH:-agent/$ID}"
WT="$FARM/worktrees/$ID"
# The task's title without the "Fix: ... (round N)" wrapper that bin/pm.sh adds
ORIG_TITLE="$(printf '%s' "$TITLE" | sed -E 's/^Fix: (.*) \(round [0-9]+\)$/\1/')"
mkdir -p "$FARM/logs" "$FARM/worktrees" "$FARM/state" "$FARM/tasks/failed"

# Notify the human that a fix round needs them; the body comes from stdin. Never fails the run.
notify_human() { NOTIFY_TASK="$ID" "$FARM/bin/notify.sh" needs_human "$1" - || true; }

# Refuse a fix round before any work: move the task to tasks/failed/ with the reason, optionally notify, exit 2.
#   refuse <reason> [notify=1]
refuse() {
  echo "[$ID] fix round not run: $1" >&2
  case "$TASK" in "$FARM/tasks/running/"*)
    mv "$TASK" "$FARM/tasks/failed/$ID.md"
    printf '\n> Farm: fix round not run (%s): %s\n' "$(date -Iseconds)" "$1" >> "$FARM/tasks/failed/$ID.md" ;;
  esac
  status failed id="$ID" repo="$REPO" branch="$BRANCH" title="$TITLE" round="$ROUND" pr="$EXISTING_PR" reason="$1"
  [ "${2:-1}" = 1 ] && printf 'Fix round %s for %s was not run.\nReason: %s\nBranch: %s\nTask: %s\n' \
    "$ROUND" "${EXISTING_PR:-?}" "$1" "$BRANCH" "$ID" | notify_human "Fix round $ROUND blocked: $ORIG_TITLE"
  exit 2
}

# A fix round only makes sense while its PR is open
if [ -n "$FIX_BRANCH" ] && [ -n "$EXISTING_PR" ]; then
  pr_state="$(cd "$REPO" && gh pr view "$EXISTING_PR" --json state -q .state 2>/dev/null || true)"
  case "$pr_state" in
    MERGED|CLOSED) refuse "PR $EXISTING_PR is $pr_state" 0 ;;
    OPEN) ;;
    *) echo "[$ID] WARNING: could not read the state of $EXISTING_PR; continuing" >&2 ;;
  esac
fi

if [ -n "$(git -C "$REPO" status --porcelain -- .claude/skills 2>/dev/null)" ]; then
  echo "WARNING: $REPO has uncommitted changes in .claude/skills; agents will NOT see them (commit first)" >&2
fi

# Isolated worktree + branch per task, so parallel agents never collide
BASE_BRANCH="$(fm base_branch)"
[ -n "$BASE_BRANCH" ] || BASE_BRANCH="$(git -C "$REPO" symbolic-ref --quiet --short HEAD || echo main)"
if [ -n "$FIX_BRANCH" ]; then
  # Reuse the farm worktree that already has the branch checked out, if any
  existing="$(git -C "$REPO" worktree list --porcelain \
              | awk -v b="refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0=="branch "b{print p;exit}')"
  fetched=0
  if [ -n "$existing" ] && [ "${existing#"$FARM/worktrees/"}" != "$existing" ] && [ -d "$existing" ]; then
    WT="$existing"
  else
    [ -n "$existing" ] && refuse "branch $BRANCH is checked out outside the farm ($existing)"
    # Name the worktree after the branch, so bin/cleanup.sh maps worktrees/<x> back to agent/<x>
    slug="${BRANCH#agent/}"; WT="$FARM/worktrees/${slug//\//-}"
    [ -e "$WT" ] && refuse "worktree path already exists: $WT"
    if ! git -C "$REPO" show-ref --verify -q "refs/heads/$BRANCH"; then
      git -C "$REPO" fetch -q origin "$BRANCH:$BRANCH" || refuse "branch $BRANCH not found locally or on origin"
      fetched=1
    fi
    git -C "$REPO" worktree add -q "$WT" "$BRANCH" || refuse "could not add a worktree for $BRANCH"
  fi
  # Never run over someone's uncommitted work: a later reset (usage limit) must only drop this run's changes
  [ -z "$(git -C "$WT" status --porcelain)" ] || refuse "worktree $WT has uncommitted changes"
  # Bring a reused local branch up to date with the PR (e.g. commits pushed by a human)
  if [ "$fetched" = 0 ] && git -C "$REPO" fetch -q origin "$BRANCH" 2>/dev/null \
     && git -C "$REPO" rev-parse --verify -q "refs/remotes/origin/$BRANCH" >/dev/null; then
    git -C "$WT" merge -q --ff-only "origin/$BRANCH" >/dev/null 2>&1 \
      || refuse "local $BRANCH cannot fast-forward to origin/$BRANCH (diverged)"
  fi
  BASE="$(git -C "$WT" rev-parse --short HEAD)"
else
  BASE="$(git -C "$REPO" rev-parse --short HEAD)"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT"
fi
START="$(git -C "$WT" rev-parse HEAD)"
node "$FARM/bin/build-agents.js" "$FARM/agents" > "$LOG.agents.json"
node "$FARM/bin/build-agents.js" --body "$FARM/agents/orchestrator.md" > "$LOG.orchestrator.md"
cp "$TASK" "$LOG.task.md"

status started id="$ID" repo="$REPO" branch="$BRANCH" title="$TITLE" model="$MODEL" pid="$$" round="$ROUND" pr="$EXISTING_PR"
echo "[$ID] started  repo=$REPO branch=$BRANCH model=$MODEL${FIX_BRANCH:+ fix-round=$ROUND}"

# Fix rounds get one extra line telling the orchestrator to stay on the PR's branch
FIX_LINE=""
[ -n "$FIX_BRANCH" ] && FIX_LINE="FIX ROUND $ROUND for PR ${EXISTING_PR:-?} on branch $BRANCH (base: $BASE_BRANCH). Commit on this branch; review the whole PR diff against origin/$BASE_BRANCH."

ADD_DIR=(); [ -d "$HOME/skills" ] && ADD_DIR=(--add-dir "$HOME/skills")
set +e
( cd "$WT" && timeout "$TIMEOUT" claude -p "$(printf 'MODE: unattended\n\n'; [ -n "$FIX_LINE" ] && printf '%s\n\n' "$FIX_LINE"; cat "$TASK")" \
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
  fs.writeFileSync(process.argv[2], (r.result || "STATUS: FAILED\n\nNo result: the run crashed, timed out or was stopped. See the .err log.") + "\n");
' "$LOG.json" "$LOG.report.md"

# Hit the Pro usage limit? Put the task back in the queue and pause dispatching for a while.
if [ $RC -ne 0 ] && grep -qiE 'usage limit|rate.?limit|limit reached|hit your limit|overloaded' "$LOG.err" "$LOG.report.md" 2>/dev/null; then
  if [ -n "$FIX_BRANCH" ]; then
    # Keep the PR's branch and worktree; only drop this run's partial work
    git -C "$WT" reset -q --hard "$START" 2>/dev/null || true
    git -C "$WT" clean -qfd 2>/dev/null || true
  else
    git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
    git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 || true
  fi
  case "$TASK" in "$FARM/tasks/running/"*) mv "$TASK" "$FARM/tasks/inbox/" ;; esac
  # Never shorten a longer pause (e.g. one set by the usage gate until a window resets)
  # shellcheck source=lib/usage-gate.sh
  source "$FARM/bin/lib/usage-gate.sh"
  paused_until="$(set_pause "$(date -d "+$(pause_minutes) minutes" +%s)")"
  status requeued id="$ID" reason="usage limit"
  echo "[$ID] requeued: usage limit reached; dispatching paused until $(pause_time "$paused_until")"
  exit 3
fi

if [ $RC -eq 0 ] && head -1 "$LOG.report.md" | grep -q "STATUS: SUCCESS"; then
  STATUS=done
else
  STATUS=failed
  [ $RC -eq 124 ] && echo "(timed out after ${TIMEOUT}s)" >> "$LOG.report.md"
fi

# Open a PR (GitHub remotes only). Agents never push; this script does, and it never merges.
#   success                       -> push + PR (fix round: push to the existing PR + comment)
#   failed, new task, has commits -> push + draft PR "[WIP] <title>" (no PM step, no notification)
#   failed, new task, no commits  -> nothing to push
#   failed fix round with commits -> push to the existing PR + "FAILED" report comment, then needs_human (below)
#   failed fix round, no commits  -> nothing to push, needs_human (below)
# A usage-limit requeue never gets here: it resets the branch and exits above, so it never pushes.
PR_URL=""; PUSH_FAILED=0; DRAFT=0; FIX_PUSH=0
if [ "$PR" = 1 ] && [ "$STATUS" = failed ] && [ -z "$EXISTING_PR" ] && [ -z "$FIX_BRANCH" ] \
   && [ "$(git -C "$REPO" rev-list --count "$BASE..$BRANCH" 2>/dev/null || echo 0)" -gt 0 ]; then
  DRAFT=1
fi
# A failed fix round still publishes its own new commits (beyond START) to the PR's branch
if [ "$PR" = 1 ] && [ "$STATUS" = failed ] && [ -n "$EXISTING_PR" ] \
   && [ "$(git -C "$REPO" rev-list --count "$START..$BRANCH" 2>/dev/null || echo 0)" -gt 0 ]; then
  FIX_PUSH=1
fi
if [ "$PR" = 1 ] && { [ "$STATUS" = done ] || [ "$DRAFT" = 1 ] || [ "$FIX_PUSH" = 1 ]; }; then
  if git -C "$REPO" remote get-url origin 2>/dev/null | grep -q 'github.com'; then
    { tail -n +2 "$LOG.report.md"
      [ "$DRAFT" = 1 ] && printf '\n> **Draft:** this run did not pass tests and review (STATUS: FAILED). The branch holds its partial work for a human to finish or close.\n'
      printf '\n---\nTask: `%s` · Branch: `%s`\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' "$NAME" "$BRANCH"
    } > "$LOG.pr.md"
    if [ -n "$EXISTING_PR" ]; then
      # Fix round: pushing the same branch updates the PR; the round's report goes on as a comment
      if git -C "$REPO" push -q -u origin "$BRANCH" 2>>"$LOG.err"; then
        PR_URL="$EXISTING_PR"
        echo "[$ID] PR updated: $PR_URL"
        { printf '## Fix round %s report (orchestrator)%s\n\n' "$ROUND" "$([ "$STATUS" = failed ] && echo ': FAILED')"
          cat "$LOG.pr.md"; } > "$LOG.pr-comment.md"
        (cd "$REPO" && gh pr comment "$PR_URL" --body-file "$LOG.pr-comment.md" >/dev/null 2>>"$LOG.err") \
          || echo "[$ID] WARNING: could not comment the fix-round report on the PR (see $LOG.err)" >&2
      else
        echo "[$ID] WARNING: could not push $BRANCH to update $EXISTING_PR (see $LOG.err)" >&2
        PUSH_FAILED=1
      fi
    elif [ "$DRAFT" = 1 ]; then
      if git -C "$REPO" push -q -u origin "$BRANCH" 2>>"$LOG.err" \
         && PR_URL="$(cd "$REPO" && gh pr create --draft --head "$BRANCH" --base "$BASE_BRANCH" --title "[WIP] $TITLE" --body-file "$LOG.pr.md" 2>>"$LOG.err" | tail -1)"; then
        echo "[$ID] draft PR opened: $PR_URL"
      else
        echo "[$ID] WARNING: could not open a draft PR (see $LOG.err); if the push succeeded the branch is on GitHub without a PR" >&2
        PR_URL=""; DRAFT=0
      fi
    elif git -C "$REPO" push -q -u origin "$BRANCH" 2>>"$LOG.err" \
       && PR_URL="$(cd "$REPO" && gh pr create --head "$BRANCH" --base "$BASE_BRANCH" --title "$TITLE" --body-file "$LOG.pr.md" 2>>"$LOG.err" | tail -1)"; then
      echo "[$ID] PR opened: $PR_URL"
    else
      echo "[$ID] WARNING: could not open a PR (see $LOG.err); if the push succeeded the branch is on GitHub without a PR" >&2
      PR_URL=""
    fi
  else
    echo "[$ID] no GitHub remote: skipping PR, work is on local branch $BRANCH"
    DRAFT=0; FIX_PUSH=0
  fi
fi
# Mark a new PR (normal or draft) that is part of a stack: merge hints + `stacked` label on it and its parent.
# A one-off PR (default branch, nothing on top) is left unchanged. Labelling never fails the run.
if [ -n "$PR_URL" ] && [ -z "$EXISTING_PR" ]; then
  "$FARM/bin/pr-stack-label.sh" "$PR_URL" "$REPO" 2>>"$LOG.err" | sed "s/^/[$ID] /" \
    || echo "[$ID] WARNING: could not mark $PR_URL as stacked (see $LOG.err)" >&2
fi

# Move the task out of tasks/running if it came from the queue
FINISHED="$LOG.task.md"
case "$TASK" in "$FARM/tasks/running/"*) mv "$TASK" "$FARM/tasks/$STATUS/$ID.md"; FINISHED="$FARM/tasks/$STATUS/$ID.md" ;; esac
status "$STATUS" id="$ID" pr="$PR_URL" draft="$DRAFT" report="$LOG.report.md"

echo "[$ID] $STATUS  report=$LOG.report.md"
[ -z "$PR_URL" ] && echo "        review:  git -C $REPO log --stat $BASE..$BRANCH   (or open $WT)"

# A fix round that failed, or could not update its PR, is a dead end without a human
if [ -n "$EXISTING_PR" ] && { [ "$STATUS" = failed ] || [ "$PUSH_FAILED" = 1 ]; }; then
  if [ "$STATUS" = done ]; then outcome="succeeded but could not be pushed (see $LOG.err)"
  elif [ "$PUSH_FAILED" = 1 ]; then outcome="failed, and pushing its commits failed too (see $LOG.err)"
  elif [ "$FIX_PUSH" = 1 ]; then outcome="failed; its commits were pushed to the PR and the report was commented on it"
  else outcome="failed"; fi
  { printf 'Fix round %s for %s %s.\nPR: %s\nBranch: %s (worktree %s)\nReport: %s\n\n' "$ROUND" "$EXISTING_PR" \
      "$outcome" "$EXISTING_PR" "$BRANCH" "$WT" "$LOG.report.md"
    cat "$LOG.report.md"
  } | notify_human "Fix round $ROUND failed: $ORIG_TITLE"
fi

# Project manager: decide READY / FIX / NEEDS_HUMAN for the PR. Its outcome never changes this run's exit code.
if [ "$STATUS" = done ] && [ -n "$PR_URL" ] && [ "${PM:-1}" = 1 ]; then
  # Record the run on the finished-task copy's frontmatter (replacing any older values) for bin/pm.sh
  node -e '
    const fs = require("fs");
    const [file, ...pairs] = process.argv.slice(1);
    const set = Object.fromEntries(pairs.map((p) => [p.slice(0, p.indexOf("=")), p.slice(p.indexOf("=") + 1)]));
    const text = fs.readFileSync(file, "utf8");
    const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    const keep = (m ? m[1].split("\n") : []).filter((l) => !Object.keys(set).includes(l.slice(0, l.indexOf(":")).trim()));
    const head = [...keep, ...Object.entries(set).map(([k, v]) => `${k}: ${v}`)].join("\n");
    fs.writeFileSync(file, `---\n${head}\n---\n${m ? m[2] : text}`);
  ' "$FINISHED" repo="$REPO" pr="$PR_URL" branch="$BRANCH" round="$ROUND" base_branch="$BASE_BRANCH" id="$ID" name="$NAME" \
    && "$FARM/bin/pm.sh" "$FINISHED" \
    || echo "[$ID] WARNING: project-manager step failed (see $LOG.pm-r$ROUND.err)" >&2
fi
[ "$STATUS" = done ]
