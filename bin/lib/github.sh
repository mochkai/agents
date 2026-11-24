# shellcheck shell=bash
# Shared GitHub helpers for bin/pr-stack-label.sh and bin/restack.sh.
#   usage: source "$FARM/bin/lib/github.sh"
# Writes go through the REST API (`gh api`), never `gh pr edit`: on some accounts `gh pr edit` fails with
# the GraphQL "Projects (classic) is being deprecated" error.

# The label for PRs that depend on another open PR, and its description on GitHub
STACKED_LABEL="stacked"
STACKED_LABEL_DESC='Depends on another open PR. Merge with "Create a merge commit", bottom of the stack first.'

# Print one field of the JSON on stdin, by dot path (`head.ref`, `0.number`); empty when missing or null.
# Objects and arrays are printed as JSON.
#   json_get <path>
json_get() {
  node -e '
    let v = JSON.parse(require("fs").readFileSync(0, "utf8"));
    for (const k of process.argv[1].split(".")) v = v == null ? undefined : v[k];
    process.stdout.write(v == null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
  ' "$1"
}

# Print the repo's GitHub "owner/name", from the origin URL (https or ssh), else from `gh repo view`.
#   repo_slug <repo-dir>
repo_slug() {
  local url slug
  url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  # github.com/<owner>/<name>[.git], github.com:<owner>/<name>[.git]
  slug="$(printf '%s' "$url" | sed -nE 's#.*github\.com[:/]+([^/]+)/([^/]+)$#\1/\2#p' | sed -E 's/\.git$//')"
  [ -n "$slug" ] || slug="$(cd "$1" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$slug" ] || return 1
  printf '%s\n' "$slug"
}

# Print the repo's default branch: GitHub's defaultBranchRef, else origin/HEAD, else main or master
# (whichever exists on origin), else main.
#   default_branch <repo-dir>
default_branch() {
  local name
  name="$(cd "$1" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  [ -n "$name" ] || name="$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [ -z "$name" ]; then
    for name in main master ""; do
      [ -n "$name" ] || break
      git -C "$1" ls-remote --exit-code -q --heads origin "$name" >/dev/null 2>&1 && break
    done
  fi
  printf '%s\n' "${name:-main}"
}
