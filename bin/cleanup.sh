#!/usr/bin/env bash
# Remove worktrees and local branches of finished agent tasks.
#   usage: bin/cleanup.sh [--dry-run]
# A task is cleaned up when its PR is merged or closed, or (for local-only work) when its
# branch is already merged into the base branch. Anything else is left alone.
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
shopt -s nullglob

for wt in "$FARM"/worktrees/*/; do
  wt="${wt%/}"; id="$(basename "$wt")"; branch="agent/$id"
  common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || { echo "? $id: not a git worktree, skipped"; continue; }
  repo="$(cd "$wt" && cd "$common/.." && pwd)"

  state=""
  if git -C "$repo" remote get-url origin 2>/dev/null | grep -q github.com; then
    state="$(cd "$repo" && gh pr view "$branch" --json state -q .state 2>/dev/null || true)"
  fi
  if [ -z "$state" ]; then
    base="$(git -C "$repo" symbolic-ref --quiet --short HEAD || echo main)"
    git -C "$repo" merge-base --is-ancestor "$branch" "$base" 2>/dev/null && state="MERGED-LOCAL"
  fi

  case "$state" in
    MERGED|CLOSED|MERGED-LOCAL)
      echo "- $id ($state)"
      if [ $DRY = 0 ]; then
        git -C "$repo" worktree remove --force "$wt"
        git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
        node "$FARM/bin/status.js" cleaned id="$id" pr_state="$state" || true
      fi ;;
    *) echo "  $id (${state:-no PR, not merged}): kept" ;;
  esac
done
