#!/usr/bin/env bash
# Mark the PRs of a stack: a PR whose base is not its repo's default branch gets a merge hint and the
# `stacked` label, and so does its parent (the bottom of the stack). A PR with no parent and no children
# (a one-off) is left unchanged.
#   usage: bin/pr-stack-label.sh <pr-url-or-number> [repo-dir]
# repo-dir (default: the current directory) is only used to find the GitHub repo for a bare PR number;
# with a URL everything comes from GitHub, so it can run from anywhere. Used by bin/run-task.sh after it
# opens a PR, and by the interactive orchestrator (agents/orchestrator.md, step 9), so both behave the same.
#
# For PR #N (all lookups in the PR's own repo; the default branch is `base.repo.default_branch`):
#   - stacked (base is not the default branch): the parent is the open PR whose head is <base> in this repo
#     (`pulls?state=open&head=<owner>:<base>`). #N gets, at the top of its description:
#       > **Stacked on #<P> (`<base>`).** Merge that PR first, then merge this one with **"Create a merge commit"**.
#     (just "Stacked on `<base>`." when no open parent PR is found), and the parent #P gets the bottom note
#     below, pointing at #N.
#   - has children (open PRs whose base is #N's head branch, `pulls?state=open&base=<head>`), whatever its
#     base: #N gets the bottom note pointing at the first child:
#       > **Bottom of a stack:** #<child> is based on this branch. Merge with **"Create a merge commit"**. If it was rebase/squash-merged by mistake, run `bin/restack.sh <child>`.
#   - every PR that got a note also gets the `stacked` label (created in the repo if missing).
# Notes are prepended once (a re-run finds them and skips), keeping the rest of the body byte for byte.
# Everything goes through the REST API (`gh api`), never `gh pr edit` (see bin/lib/github.sh).
#
# Exit codes: 0 labelled, or nothing to do (one-off PR); 1 a GitHub call failed (callers only warn); 2 bad input
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 2; }
# shellcheck source=lib/github.sh
source "$FARM/bin/lib/github.sh"

[ $# -ge 1 ] || die "usage: $0 <pr-url-or-number> [repo-dir]"
DIR="${2:-.}"
[ -d "$DIR" ] || die "repo dir not found: $DIR"
DIR="$(cd "$DIR" && pwd)"

# Accept https://github.com/<owner>/<name>/pull/<n>, #<n> or <n>
REF="$1"
case "$REF" in
  http*://*/pull/*) N="${REF##*/pull/}"; N="${N%%[/?#]*}"
                    SLUG="$(printf '%s' "$REF" | sed -nE 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#p')" ;;
  *) N="${REF#\#}"; SLUG="" ;;
esac
[[ "$N" =~ ^[0-9]+$ ]] || die "not a PR number or URL: $REF"
[ -n "$SLUG" ] || SLUG="$(repo_slug "$DIR")" || die "cannot tell the GitHub repo of $DIR"

PR_JSON="$(gh api "repos/$SLUG/pulls/$N")" || { echo "WARNING: could not read PR #$N of $SLUG" >&2; exit 1; }
# The PR's own repo decides everything (not the directory this runs in)
PR_REPO="$(printf '%s' "$PR_JSON" | json_get base.repo.full_name)"
SLUG="${PR_REPO:-$SLUG}"
OWNER="${SLUG%%/*}"
BASE="$(printf '%s' "$PR_JSON" | json_get base.ref)"
HEAD="$(printf '%s' "$PR_JSON" | json_get head.ref)"
HEAD_REPO="$(printf '%s' "$PR_JSON" | json_get head.repo.full_name)"
DEFAULT="$(printf '%s' "$PR_JSON" | json_get base.repo.default_branch)"
[ -n "$DEFAULT" ] || DEFAULT="$(default_branch "$DIR")"
[ -n "$BASE" ] || die "PR #$N: GitHub returned no base branch"

RC=0; LABEL_READY=0

# Print the number of the first open PR in this repo matching the query (`head=<owner>:<branch>` or
# `base=<branch>`), or nothing.
#   first_open_pr <query>
first_open_pr() {
  gh api "repos/$SLUG/pulls?state=open&$1&per_page=10" 2>/dev/null | json_get 0.number || true
}

# Prepend a note to a PR's description unless a line starting with <marker> is already there. The body is
# read and rewritten by node, so its text (and trailing newline) is kept exactly and escaped correctly.
# <kind> only names the note in messages.
#   add_note <pr> <kind> <marker> <note>
add_note() {
  local json req
  json="$(gh api "repos/$SLUG/pulls/$1")" || { echo "WARNING: could not read PR #$1" >&2; RC=1; return 0; }
  req="$(printf '%s' "$json" | node -e '
    const pr = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const [marker, note] = process.argv.slice(1);
    const body = pr.body || "";
    if (body.split("\n").some((l) => l.startsWith(marker))) process.exit(0);
    process.stdout.write(JSON.stringify({ body: body ? `${note}\n\n${body}` : note }));
  ' "$3" "$4")"
  if [ -z "$req" ]; then
    echo "PR #$1: $2 note already present"
  elif printf '%s' "$req" | gh api -X PATCH "repos/$SLUG/pulls/$1" --input - >/dev/null; then
    echo "PR #$1: $2 note added"
  else
    echo "WARNING: could not add the $2 note to PR #$1" >&2; RC=1
  fi
}

# Add the `stacked` label to a PR, creating the label in the repo first if it is missing.
#   add_label <pr>
add_label() {
  if [ "$LABEL_READY" = 0 ] && ! gh api "repos/$SLUG/labels/$STACKED_LABEL" >/dev/null 2>&1; then
    gh api -X POST "repos/$SLUG/labels" -f name="$STACKED_LABEL" -f color=fbca04 \
      -f description="$STACKED_LABEL_DESC" >/dev/null 2>&1 \
      || echo "WARNING: could not create the '$STACKED_LABEL' label in $SLUG" >&2
  fi
  LABEL_READY=1
  if gh api -X POST "repos/$SLUG/issues/$1/labels" -f "labels[]=$STACKED_LABEL" >/dev/null; then
    echo "PR #$1: '$STACKED_LABEL' label added"
  else
    echo "WARNING: could not add the '$STACKED_LABEL' label to PR #$1" >&2; RC=1
  fi
}

# The note that marks <parent> as the bottom of a stack whose next PR is <child>.
#   bottom_note <child>
bottom_note() {
  printf '%s **Bottom of a stack:** #%s is based on this branch. Merge with **"Create a merge commit"**. If it was rebase/squash-merged by mistake, run `bin/restack.sh %s`.' '>' "$1" "$1"
}
BOTTOM_MARKER="> **Bottom of a stack:**"
STACKED_MARKER="> **Stacked on "

MARKED=0
# Stacked on another PR: note + label here, and mark the parent as the bottom of the stack
if [ "$BASE" != "$DEFAULT" ]; then
  PARENT="$(first_open_pr "head=$OWNER:$BASE")"
  [[ "$PARENT" =~ ^[0-9]+$ ]] || PARENT=""
  if [ -n "$PARENT" ]; then ON="#$PARENT (\`$BASE\`)"; else ON="\`$BASE\`"; fi
  add_note "$N" stacked "$STACKED_MARKER" "$STACKED_MARKER$ON.** Merge that PR first, then merge this one with **\"Create a merge commit\"**."
  add_label "$N"; MARKED=1
  if [ -n "$PARENT" ]; then
    add_note "$PARENT" bottom-of-stack "$BOTTOM_MARKER" "$(bottom_note "$N")"
    add_label "$PARENT"
  fi
fi
# Other PRs are based on this one's branch (only branches in this repo; a fork's branch can't be a base)
if [ -n "$HEAD" ] && [ "$HEAD_REPO" = "$SLUG" ]; then
  CHILD="$(first_open_pr "base=$HEAD")"
  if [[ "$CHILD" =~ ^[0-9]+$ ]]; then
    add_note "$N" bottom-of-stack "$BOTTOM_MARKER" "$(bottom_note "$CHILD")"
    [ "$MARKED" = 1 ] || add_label "$N"
    MARKED=1
  fi
fi
[ "$MARKED" = 1 ] || echo "PR #$N targets the default branch ($DEFAULT) and has no stacked PRs: one-off PR, no stacked label"
exit $RC
