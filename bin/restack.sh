#!/usr/bin/env bash
# Repair a stacked child PR after its parent was merged with "Rebase and merge" or "Squash and merge".
#   usage: bin/restack.sh [--dry-run] [--parent <pr>] <child-pr-number> [repo-dir]
# repo-dir defaults to the current directory.
#
# The situation: parent PR P was rebase/squash-merged into T, so its commits got new SHAs on T. Child PR C
# (retargeted to T, or still on P's merged branch) was built on P's old head and now shows conflicts, although
# the content is identical. The repair records T as merged into C with `git merge -s ours`: C's files stay
# exactly as they are, and the PR diff against T shrinks to C's own changes again.
#
# Steps:
#   1. Read C (head, base). P is the merged PR whose head was C's base; if C already targets a branch, P is the
#      most recently merged PR into that branch whose old head C is built on. --parent <pr> names P directly.
#      T is the branch P was merged into.
#   2. Safety check: T's tip must have exactly the content of P's head as merged
#      (`git diff --quiet origin/<T> <P-head>`). Anything else on T needs a normal merge or rebase: abort.
#   3. In a temporary git worktree (never your checkout; detached, so no local branch is touched):
#      `git merge -s ours origin/<T>` on C's head, then check that `git diff origin/<T> HEAD` equals
#      `git diff <P-head> <C-head-before>`, i.e. C still changes exactly the same things. Otherwise abort.
#   4. Push the merge commit to C's branch (a normal push, NEVER a force push; it fails if the branch moved),
#      retarget C to T through the REST API if needed, and print C's new mergeable state.
# With --dry-run it does steps 1-3 and reports, without pushing or retargeting.
# It never force-pushes, never merges into T and never touches any branch but C's.
# Records a `restacked` status event (bin/status.js) after a push.
#
# Environment:
#   RESTACK_POLL=5   times to poll (2 s apart) for C's mergeable state after the push (0 = don't wait)
#
# Exit codes: 0 restacked, nothing to do, or dry run OK; 1 aborted (safety check failed, push failed); 2 bad input
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 2; }
abort() { echo "ABORT: $*" >&2; echo "Nothing was pushed or changed." >&2; exit 1; }
status() { node "$FARM/bin/status.js" "$@" || true; }
# shellcheck source=lib/github.sh
source "$FARM/bin/lib/github.sh"

DRY=0; PARENT_ARG=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --parent) [ $# -ge 2 ] || die "--parent needs a PR number"; PARENT_ARG="${2#\#}"; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
[ ${#ARGS[@]} -ge 1 ] || die "usage: $0 [--dry-run] [--parent <pr>] <child-pr-number> [repo-dir]"
C="${ARGS[0]#\#}"
[[ "$C" =~ ^[0-9]+$ ]] || die "not a PR number: ${ARGS[0]}"
[ -z "$PARENT_ARG" ] || [[ "$PARENT_ARG" =~ ^[0-9]+$ ]] || die "not a PR number: $PARENT_ARG"
DIR="${ARGS[1]:-.}"
[ -d "$DIR" ] || die "repo dir not found: $DIR"
DIR="$(cd "$DIR" && pwd)"
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$DIR is not a git repo"
SLUG="$(repo_slug "$DIR")" || die "cannot tell the GitHub repo of $DIR"
OWNER="${SLUG%%/*}"

# --- 1. The child, its parent and the target branch ---------------------------------------------------
C_JSON="$(gh api "repos/$SLUG/pulls/$C")" || die "could not read PR #$C of $SLUG"
[ "$(printf '%s' "$C_JSON" | json_get state)" = open ] || abort "PR #$C is not open"
C_BRANCH="$(printf '%s' "$C_JSON" | json_get head.ref)"
C_HEAD="$(printf '%s' "$C_JSON" | json_get head.sha)"
C_BASE="$(printf '%s' "$C_JSON" | json_get base.ref)"
[ "$(printf '%s' "$C_JSON" | json_get head.repo.full_name)" = "$SLUG" ] \
  || abort "PR #$C comes from another repository (a fork); restack it there"
[ -n "$C_BRANCH" ] && [ -n "$C_HEAD" ] && [ -n "$C_BASE" ] || die "PR #$C: incomplete data from GitHub"
echo "child  #$C  $C_BRANCH @ ${C_HEAD:0:9}  (base $C_BASE)"

git -C "$DIR" fetch -q origin "+refs/heads/$C_BRANCH:refs/remotes/origin/$C_BRANCH" \
  || die "could not fetch $C_BRANCH from origin"
# The head GitHub reports may not be on the branch any more; refs/pull/<n>/head keeps it
git -C "$DIR" cat-file -e "$C_HEAD^{commit}" 2>/dev/null \
  || git -C "$DIR" fetch -q origin "refs/pull/$C/head" 2>/dev/null || true
git -C "$DIR" cat-file -e "$C_HEAD^{commit}" 2>/dev/null || abort "commit $C_HEAD of PR #$C is not available locally"

# Print "<number> <head-sha> <base-ref>" of the merged PR in the JSON list on stdin that C is built on,
# most recently merged first. Only PRs whose old head is an ancestor of C's head count. With "strict", the
# old head must also be missing from the branch the PR was merged into (its commits got new SHAs there), so
# older PRs that C merely contains through that branch's history are skipped.
#   pick_parent [strict]
pick_parent() {
  local line n sha base
  node -e '
    const prs = [].concat(JSON.parse(require("fs").readFileSync(0, "utf8")));
    prs.filter((p) => p && p.merged_at && p.number !== Number(process.argv[1]))
       .sort((a, b) => Date.parse(b.merged_at) - Date.parse(a.merged_at))
       .forEach((p) => console.log(`${p.number} ${p.head.sha} ${p.base.ref}`));
  ' "$C" | while read -r line; do
    read -r n sha base <<< "$line"
    git -C "$DIR" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$DIR" fetch -q origin "refs/pull/$n/head" 2>/dev/null || true
    git -C "$DIR" merge-base --is-ancestor "$sha" "$C_HEAD" 2>/dev/null || continue
    if [ "${1:-}" = strict ]; then
      git -C "$DIR" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null || continue
      git -C "$DIR" merge-base --is-ancestor "$sha" "origin/$base" 2>/dev/null && continue
    fi
    echo "$line"; break
  done
}

if [ -n "$PARENT_ARG" ]; then
  P_LINE="$(gh api "repos/$SLUG/pulls/$PARENT_ARG" | pick_parent)" || die "could not read PR #$PARENT_ARG"
  [ -n "$P_LINE" ] || abort "PR #$PARENT_ARG is not merged, or #$C is not built on its final head"
else
  # C still targets the parent's branch: the merged PR from that branch
  P_LINE="$(gh api "repos/$SLUG/pulls?state=closed&head=$OWNER:$C_BASE&per_page=20" | pick_parent)" \
    || die "could not list the PRs from $C_BASE"
  if [ -z "$P_LINE" ]; then
    # C was already retargeted: a PR merged into C's base that C was built on (its old head is in C)
    P_LINE="$(gh api "repos/$SLUG/pulls?state=closed&base=$C_BASE&sort=updated&direction=desc&per_page=30" | pick_parent strict)" \
      || die "could not list the PRs merged into $C_BASE"
  fi
  [ -n "$P_LINE" ] || abort "found no merged parent PR that #$C is built on (pass --parent <pr> to name it)"
fi
read -r P P_HEAD T <<< "$P_LINE"
echo "parent #$P  head ${P_HEAD:0:9}, merged into $T"
[ "$T" != "$C_BRANCH" ] || abort "parent #$P was merged into #$C's own branch"

# Point C at T through the REST API (never `gh pr edit`). A failure only warns: the push already happened.
retarget() {
  if gh api -X PATCH "repos/$SLUG/pulls/$C" -f base="$T" >/dev/null; then
    echo "retargeted #$C: $C_BASE -> $T"
  else
    echo "WARNING: could not retarget #$C to $T; change its base on GitHub" >&2
  fi
}

git -C "$DIR" fetch -q origin "+refs/heads/$T:refs/remotes/origin/$T" || die "could not fetch $T from origin"
if git -C "$DIR" merge-base --is-ancestor "origin/$T" "origin/$C_BRANCH"; then
  echo "origin/$T is already part of $C_BRANCH: nothing to restack"
  if [ "$C_BASE" != "$T" ]; then
    if [ $DRY = 1 ]; then echo "dry run: would retarget #$C from $C_BASE to $T"; else retarget; fi
  fi
  exit 0
fi

# --- 2. Safety check: T holds exactly P's content ------------------------------------------------------
if ! git -C "$DIR" diff --quiet "origin/$T" "$P_HEAD"; then
  echo "origin/$T differs from #$P's merged head ${P_HEAD:0:9}:" >&2
  git -C "$DIR" diff --stat "$P_HEAD" "origin/$T" >&2 || true
  abort "$T has changes beyond #$P (something else was merged), so a content-preserving restack is not safe. Merge or rebase origin/$T into $C_BRANCH normally and resolve the conflicts."
fi
echo "check  origin/$T has exactly #$P's content: OK"

# --- 3. Merge -s ours in a temporary worktree and verify C's diff is unchanged --------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/restack-$C.XXXXXX")"
WT="$TMP/wt"
cleanup() { git -C "$DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
# Detached at the branch tip, so no local branch (and not your checkout) is touched
git -C "$DIR" worktree add -q --detach "$WT" "origin/$C_BRANCH" || abort "could not create a temporary worktree"
C_TIP="$(git -C "$WT" rev-parse HEAD)"
MSG="Merge $T into $C_BRANCH (restack after #$P was rebased; content unchanged)"
git -C "$WT" merge -q --no-edit -s ours "origin/$T" -m "$MSG" >/dev/null || abort "git merge -s ours failed"
git -C "$DIR" diff --binary "origin/$T" "$(git -C "$WT" rev-parse HEAD)" > "$TMP/after.diff"
git -C "$DIR" diff --binary "$P_HEAD" "$C_HEAD" > "$TMP/before.diff"
if ! cmp -s "$TMP/after.diff" "$TMP/before.diff"; then
  echo "diff of the restacked branch against origin/$T differs from #$C's diff against #$P's head:" >&2
  diff "$TMP/before.diff" "$TMP/after.diff" | head -40 >&2 || true
  [ "$C_TIP" = "$C_HEAD" ] || echo "(origin/$C_BRANCH is at ${C_TIP:0:9}, but GitHub reports ${C_HEAD:0:9} for #$C: the branch was changed)" >&2
  abort "the restack would change what #$C changes"
fi
NEW="$(git -C "$WT" rev-parse HEAD)"
echo "check  #$C changes exactly the same files and lines against $T: OK"
echo "merge  ${NEW:0:9}  \"$MSG\""

if [ $DRY = 1 ]; then
  echo "dry run: would push ${NEW:0:9} to $C_BRANCH (no force)$([ "$C_BASE" != "$T" ] && echo " and retarget #$C from $C_BASE to $T")"
  exit 0
fi

# --- 4. Push (never forced), retarget, report -----------------------------------------------------------
git -C "$WT" push -q origin "HEAD:refs/heads/$C_BRANCH" \
  || abort "push to $C_BRANCH was rejected (did someone push to it meanwhile?). Fetch and run restack again."
echo "pushed ${NEW:0:9} to $C_BRANCH"
[ "$C_BASE" = "$T" ] || retarget
STATE=""
for ((i = 0; i < ${RESTACK_POLL:-5}; i++)); do
  STATE="$(gh api "repos/$SLUG/pulls/$C" 2>/dev/null | json_get mergeable_state || true)"
  [ -n "$STATE" ] && [ "$STATE" != unknown ] && break
  sleep 2
done
echo "PR #$C mergeable state: ${STATE:-unknown}"
status restacked repo="$DIR" pr="$C" parent="$P" base="$T" branch="$C_BRANCH" commit="$NEW" mergeable="${STATE:-unknown}"
