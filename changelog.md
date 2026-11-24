# Changelog

All notable changes to the agent farm are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Notification emails come from the sender name "Agent Farm" (`NOTIFY_FROM_NAME`, `NOTIFY_FROM`). The README documents using a Gmail +alias and filter to label them.

### Security
- `notify.sh` strips control characters from header values, so a task title containing a newline can't inject email headers.

### Changed
- Interactive orchestrator always works on a new feature branch, pushes only that branch, and asks before pushing anything else (review of #5).
- Farm runs that fail or time out but leave commits on their branch are now pushed and opened as a **draft** PR titled `[WIP] <title>` (report plus a note that it did not pass tests or review). No project-manager step or notification for drafts. Runs without commits are unchanged, and `PR=0` still pushes nothing. The status event records the PR URL and `draft`.
- A failed (or timed-out) fix round with new commits now pushes them to the existing PR branch and comments its report as `## Fix round <n> report (orchestrator): FAILED`, then notifies `needs_human` as before (the notification now includes the PR link and says whether the push failed). The project manager never runs for failed rounds, and a usage-limit requeue still resets the branch without pushing.
- Interactive orchestrator sessions now end with a PR: after review it pushes its feature branch and opens a PR (a draft if the review did not pass) with summary, tests, review verdict and merge confidence, and gives the human the link. Hard rules: agents still never merge; only in interactive mode may the orchestrator push its own branch.
- `templates/AGENTS.md`: new CHANGE / EDIT rule to push the branch and open a PR for review (a draft if the review did not pass) and never merge it yourself.
- `bin/run-task.sh` and `bin/pm.sh` headers state explicitly that they never merge.
- Orchestrator: the run report's Review section now includes the reviewer's merge-confidence percentage. In fix rounds the orchestrator continues the PR's existing branch instead of creating a new one.
- Reviewer agent: replies now include a merge-confidence percentage, a quality-gate summary and a "Not verified" section. When the reviewed branch has an open PR, the reviewer also posts the full review as one PR comment. It never approves through the GitHub review API, and it never merges.

### Fixed
- A run that timed out or crashed without a result was requeued as if it had hit the usage limit, because the fallback report text itself contained "usage limit". The text no longer matches, so such runs now fail (and open a draft PR when they have commits).
- `cleaned` status events now remove the task from `state/status.json`. Previously they left an empty entry behind.

### Added
- Monitor: an **Interactive sessions** section in `bin/watch.js` lists Claude sessions you started yourself (project, `--agent` name or "main session", active subagent, last action, idle time), from transcripts changed in the last `ACTIVE_MINUTES` (default 15). Farm worktree runs are left out, and the header counts them (`interactive N`). `CLAUDE_PROJECTS_DIR` overrides the transcripts folder. The monitor also tolerates malformed transcripts and strips control characters from transcript text before printing it. README TODO: record interactive sessions as status events through Claude Code hooks.
- Project-manager agent (`agents/project-manager.md`) and `bin/pm.sh`: after a PR is opened or updated, it decides READY, FIX or NEEDS_HUMAN (threshold `MERGE_THRESHOLD=90`, at most `MAX_FIX_ROUNDS=2`) and posts its decision as a PR comment. Auto-merge is not enabled yet.
- Fix rounds: `bin/run-task.sh` accepts `branch:`, `pr:`, `round:` and `base_branch:` in the task frontmatter, continues the existing branch and worktree, pushes to the same PR and comments the round's report on it.
- Fix-round safety: a fix round is refused (task to `tasks/failed/`, `needs_human` notification) when its worktree has uncommitted changes or its branch cannot fast-forward to origin, and skipped when the PR is merged or closed. A failed fix round, or one that cannot push, notifies `needs_human`. The PM trusts only PR comments by the farm's own GitHub account. New settings `PM_TIMEOUT` and `PM_PERMISSION_MODE`.
- Notifications (`bin/notify.sh`): logs to `logs/notifications.log` and optionally emails through msmtp, configured in a git-ignored `.env` (see `.env.example`).
- `SCOPE` section in `templates/AGENTS.md`. It makes the global rules safe for subagents (coders implement directly) and for unattended farm runs (no questions), and limits framework-specific rules to the projects that use them.
- Live farm monitor (`bin/watch.sh`): shows the active agent, its last action, and stuck or crashed tasks.
- Orchestrator, reviewer, docs-writer and task-writer agents. Multi-project dispatcher with GitHub PRs and status events (`bin/status.js`), plus cleanup of merged work (`bin/cleanup.sh`).
- Backend (Python) and frontend (Next.js/React) coder agents that load their skills from `~/skills`.
