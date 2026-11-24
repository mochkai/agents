#!/usr/bin/env bash
# Mark a PR as stacked when its base is not the repo's default branch: prepend a merge hint to its
# description and add the `stacked` label. A PR on the default branch (a one-off) is left unchanged.
#   usage: bin/pr-stack-label.sh <pr-url-or-number> [repo-dir]
# repo-dir defaults to the current directory. Used by bin/run-task.sh after it opens a PR, and by the
# interactive orchestrator (agents/orchestrator.md, step 9), so both behave the same.
#
# For a stacked PR on base <base> it:
#   - finds the parent PR: the open PR whose head is <base> (`gh pr list --head <base> --state open`)
#   - prepends, unless already there:
#       > **Stacked on #<n> (`<base>`).** Merge that PR first, then merge this one with **"Create a merge commit"**.
#     (just "Stacked on `<base>`." when no open parent PR is found)
#   - creates the `stacked` label if the repo lacks it, and adds it to the PR
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
BASE="$(printf '%s' "$PR_JSON" | json_get base.ref)"
DEFAULT="$(default_branch "$DIR")"
if [ -z "$BASE" ] || [ "$BASE" = "$DEFAULT" ]; then
  echo "PR #$N targets the default branch ($DEFAULT): one-off PR, no stacked label"
  exit 0
fi

RC=0
# The parent is the open PR whose head branch is this PR's base
PARENT="$(cd "$DIR" && gh pr list --head "$BASE" --state open --json number -q '.[0].number' 2>/dev/null || true)"
[[ "$PARENT" =~ ^[0-9]+$ ]] || PARENT=""
if [ -n "$PARENT" ]; then ON="#$PARENT (\`$BASE\`)"; else ON="\`$BASE\`"; fi
NOTE="> **Stacked on $ON.** Merge that PR first, then merge this one with **\"Create a merge commit\"**."

# Prepend the note to the description, unless an earlier run already did
BODY="$(printf '%s' "$PR_JSON" | json_get body)"
if [ "${BODY#'> **Stacked on '}" = "$BODY" ]; then
  # Build the request JSON with node, so any text in the body is escaped correctly
  if node -e 'process.stdout.write(JSON.stringify({ body: process.argv[1] + (process.argv[2] ? "\n\n" + process.argv[2] : "") }))' \
       "$NOTE" "$BODY" | gh api -X PATCH "repos/$SLUG/pulls/$N" --input - >/dev/null; then
    echo "PR #$N: stacked note added (base $BASE${PARENT:+, parent #$PARENT})"
  else
    echo "WARNING: could not add the stacked note to PR #$N" >&2; RC=1
  fi
else
  echo "PR #$N: stacked note already present"
fi

# Create the label once per repo, then add it to the PR
if ! gh api "repos/$SLUG/labels/$STACKED_LABEL" >/dev/null 2>&1; then
  gh api -X POST "repos/$SLUG/labels" -f name="$STACKED_LABEL" -f color=fbca04 \
    -f description="$STACKED_LABEL_DESC" >/dev/null 2>&1 \
    || echo "WARNING: could not create the '$STACKED_LABEL' label in $SLUG" >&2
fi
if gh api -X POST "repos/$SLUG/issues/$N/labels" -f "labels[]=$STACKED_LABEL" >/dev/null; then
  echo "PR #$N: '$STACKED_LABEL' label added"
else
  echo "WARNING: could not add the '$STACKED_LABEL' label to PR #$N" >&2; RC=1
fi
exit $RC
