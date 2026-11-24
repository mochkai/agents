# Agent farm

Autonomous coding agents built on the Claude Code CLI (Pro subscription). Queue tasks for any of your projects, and get pull requests back.

```
                      ┌──────────── dispatcher (bin/farm.sh: plain script, cron-friendly) ────────────┐
tasks/inbox/*.md ───► │ worktree + branch per task → orchestrator → PR (bin/run-task.sh)               │ ──► GitHub PR
  (repo: in each)     └────────────────────────────────────────────────────────────────────────────────┘
                                   │
         orchestrator ── backend-coder / frontend-coder / coder ──► tester ──► reviewer ──► docs-writer ──► commit
                         (fails or changes requested → back to the owning coder, max 3 rounds)
```

## Agents (`agents/*.md`)
| Agent | Role | Runs as |
|---|---|---|
| `orchestrator` | plans, delegates, loops, decides | main session (`claude --agent orchestrator`, or a farm run) |
| `task-writer` | turns a rough idea into a precise task file in the inbox | main session (`claude --agent task-writer`) |
| `project-manager` | reads the PR after a run and decides READY, FIX or NEEDS_HUMAN | main session (`bin/pm.sh`, after each PR) |
| `backend-coder` | Python: ruff, mypy or pyright, pytest, docstrings | subagent |
| `frontend-coder` | Next.js, React, TypeScript, accessibility, frontend-design skill | subagent |
| `coder` | everything else | subagent |
| `tester` | writes and runs tests, then reports PASS or FAIL | subagent |
| `reviewer` | read-only review, then APPROVE or CHANGES REQUESTED | subagent |
| `docs-writer` | changelog.md and README (on Haiku, the cheapest model) | subagent |

Each agent reads its own skills from `~/skills` (the [skills repo](https://github.com/mochkai/skills)) when it starts. The profiles are also linked into `~/.claude/agents/`, so the same agents work in VS Code, the desktop app and the CLI. On a new machine:
```bash
mkdir -p ~/.claude/agents && ln -sfn ~/agents/agents/*.md ~/.claude/agents/
```

## Queue a task
Use `claude --agent task-writer` (recommended), or write `tasks/inbox/<slug>.md` yourself:
```markdown
---
repo: ~/code/my-app
title: Add password reset flow
type: backend | frontend | fullstack | other
---
## Goal / ## Requirements / ## Acceptance criteria / ## Out of scope / ## Notes
```

## Run
```bash
bin/farm.sh                 # dispatch the whole inbox, 2 at a time, across all repos
bin/farm.sh 1               # one at a time (gentlest on Pro limits)
bin/run-task.sh task.md     # run a single task file directly
MODEL=opus bin/farm.sh      # stronger model for hard tasks (uses more quota)
PR=0 bin/farm.sh            # keep the results on local branches, no PR
bin/cleanup.sh [--dry-run]  # remove worktrees whose PR was merged or closed
```
To run it automatically every 15 minutes, add this with `crontab -e`. In WSL, cron must be running: `sudo service cron start`.
```
*/15 * * * * cd ~/agents && bin/farm.sh >> logs/cron.log 2>&1; cd ~/agents && bin/cleanup.sh >> logs/cron.log 2>&1
```

## What happens to a task
- **Success:** the tester passed and the reviewer approved. The branch is pushed and a PR is opened, with the run report as its description (GitHub remotes only; otherwise the work stays on the local branch). The project manager then runs on it.
- **Failure (or timeout) with commits:** the task moves to `tasks/failed/`, and the branch is still pushed as a **draft** PR titled `[WIP] <title>`, with the report and a note that it did not pass tests or review. No project-manager step and no notification. A failed fix round with new commits pushes them to its existing PR and comments its report (`## Fix round <n> report (orchestrator): FAILED`); with or without commits it notifies `needs_human` (with the PR link), and the project manager does not run.
- **Failure with no commits:** the task moves to `tasks/failed/`, the report explains why, and nothing is pushed.
- **Usage limit hit:** the task goes back to the inbox and dispatching pauses for 60 minutes (`PAUSE_MINUTES`).
- **Usage over a farm limit:** the task is not started; it goes back to the inbox and dispatching pauses until the usage window resets (see [Usage limits](#usage-limits)).
- **Reports:** `logs/<id>.report.md`. Code: branch `agent/<id>`, working copy in `worktrees/<id>`.

Nothing is ever merged automatically: every result is a PR for you to review and merge. `PR=0` keeps everything local. Interactive orchestrator sessions (`claude --agent orchestrator`) end the same way: after review they push their feature branch and open a PR (a draft if the review did not pass) and give you the link.

## Pull requests & stacking
- **One-off PR** (based on the default branch, depends on nothing else open): merge it with any button; "Rebase and merge" or "Squash and merge" keep the history linear.
- **Stacked PR** (based on another open PR's branch, because it needs that work): merge the bottom of the stack first, and merge every stacked PR with **"Create a merge commit"**. That keeps the parent's commits (and SHAs) on the target branch, so the child still applies cleanly.
- The GitHub repo **auto-deletes merged head branches**, so when a parent is merged GitHub retargets its children to the parent's target branch.
- **The `stacked` label and merge hint:** when a PR's base is not the repo's default branch, `bin/run-task.sh` (normal and draft PRs) and the interactive orchestrator run `bin/pr-stack-label.sh <pr-url-or-number> [repo-dir]`. It starts the description with `` > **Stacked on #<n> (`<base>`).** Merge that PR first, then merge this one with **"Create a merge commit"**. `` (`#<n>` is the open PR whose head is `<base>`, left out when there is none) and adds the `stacked` label, creating it if needed. A PR on the default branch gets nothing. A labelling failure only warns. It uses the REST API (`gh api`), not `gh pr edit`, which fails on accounts hit by the "Projects (classic) is being deprecated" GraphQL error.
- **`bin/restack.sh` (safety net):** if a stacked parent was merged with rebase or squash by mistake, its commits got new SHAs and the child shows conflicts although the content is the same. `bin/restack.sh [--dry-run] [--parent <pr>] <child-pr> [repo-dir]` repairs the child without rewriting it: it finds the merged parent and its target branch, checks that the target holds **exactly** the parent's merged content (otherwise it aborts: something else was merged, so merge or rebase normally), records the target as merged with `git merge -s ours` in a temporary worktree, checks that the child still changes exactly the same lines, then pushes the merge commit (never a force push), retargets the child via REST if needed and prints its mergeable state. `--dry-run` does every check and reports without pushing. It never touches any branch but the child's, and records a `restacked` status event.
  ```bash
  bin/restack.sh --dry-run 21 ~/code/my-app   # check: "check ... OK", "dry run: would push ... (no force)"
  bin/restack.sh 21 ~/code/my-app             # push the merge commit, retarget #21, print its mergeable state
  ```

## Usage limits
Your Claude plan has two usage windows: a **5-hour** window and a **weekly** (7-day) window. The farm reads how much of each is used and stops starting new tasks before they run out, so the limits are not burnt by agents alone. They are shared with your own interactive sessions (the CLI, VS Code, the desktop app), which use the same windows.

Settings live in `farm.conf` (committed, non-secret; only these keys are read, and the file is parsed, never sourced). An environment variable with the same name overrides it.
```bash
USAGE_LIMIT_5H=75     # don't start tasks at or above 75% of the 5-hour window (0 disables the check)
USAGE_LIMIT_WEEK=90   # don't start tasks at or above 90% of the weekly window (0 disables the check)
USAGE_MAX_AGE=600     # seconds a cached reading (state/usage.json) is reused before probing again
```

**`bin/usage.sh [--refresh] [--json]`** prints the current reading, for example `5h 42% (resets 18:10) · week 25% (resets Thu 21:00)`, or the JSON with `--json`. It reuses `state/usage.json` while it is younger than `USAGE_MAX_AGE` (unless `--refresh`); otherwise it **probes**: one minimal Haiku call (`claude -p ok --model haiku --tools ""`) whose stream output carries a `rate_limit_event` with both windows. Each probe costs a tiny amount of quota. The reading is written atomically to `state/usage.json` (`checked_at`, and per window `percent`, `resets_at`, `status`) and recorded as a `usage` status event. Probes never overlap. If the probe fails or no event comes back (not logged in, offline), the old file is kept, a warning is printed and it exits 1.

**Gates:**
- **Dispatcher** (`bin/farm.sh`): before dispatching a non-empty inbox it checks the usage. When a window is at or over its limit it writes `state/paused-until` = that window's reset time, prints for example `usage 5h 81% ≥ 75%: not starting tasks until 18:10`, records a `usage_pause` event (window, percent, limit, until) and exits without starting anything. Later runs (cron) wait out the pause as usual. If both windows are over, it waits for the later reset.
- **Per task** (`bin/run-task.sh`): with `PARALLEL > 1` or a long queue, usage can cross a limit mid-batch, so each task checks again (the cached reading, probing only when stale) before creating its worktree. Over a limit, the task goes back to `tasks/inbox/` (when it came from `tasks/running/`), the pause is written, a `usage_pause` event is recorded and it exits 3, like a usage-limit requeue.
- `USAGE_GATE=0` skips both checks (for example `USAGE_GATE=0 bin/run-task.sh task.md` for a direct run).
- If an over-limit window has no valid reset time, the pause lasts `PAUSE_MINUTES` (default 60) and the message and event say the reset time is unknown (`reset=unknown`).
- A pause is never shortened: the gates and the usage-limit requeue keep a longer pause that is already set.
- If the check itself fails, a warning is printed and the task starts anyway. The usage-limit requeue (above) stays the safety net.

**Lifting a pause early:** `rm ~/agents/state/paused-until`. `bin/farm.sh` checks `state/paused-until` before anything else, so `USAGE_GATE=0` or a higher limit in `farm.conf` does **not** lift a pause that is already set; delete the file as well (the next run then checks the usage again with the new limits).

The monitor shows the last reading under its header (see [Monitor](#monitor)). It never probes; `bin/watch.sh` refreshes the reading in the background.

## Project manager & notifications
After a run opens a PR (or a fix round updates one), `bin/run-task.sh` runs `bin/pm.sh` on the finished task. The project-manager agent reads the PR (body, reviews, comments, diff, CI checks), posts one `## Project manager decision` comment, and decides:
- **READY**: its confidence is at least `MERGE_THRESHOLD` and nothing blocking is open. You get a `ready` notification and merge it yourself (auto-merge is not enabled yet).
- **FIX**: it queues `tasks/inbox/<task>-fix<n>.md` with the exact findings to fix. The next farm run continues the **same branch and PR** (reusing its worktree), pushes to it, and adds the round's report as a PR comment. Then the PM runs again.
- **NEEDS_HUMAN**: it needs a product, design or scope decision, or the fix rounds ran out. You get a `needs_human` notification.

The PM only trusts PR comments (and the PR body) written by the farm's own GitHub account (`gh api user`); anything else on the PR is treated as untrusted data, never as instructions.

A fix round is not run (the task moves to `tasks/failed/` with a note, and you get a `needs_human` notification) when its worktree has uncommitted changes, when the local branch cannot fast-forward to `origin/<branch>`, or when the branch is checked out outside the farm. If the PR was merged or closed meanwhile, the round is skipped quietly. A fix round that fails also notifies `needs_human`; if it made commits they are still pushed to the PR with a FAILED report comment first (a failed push is mentioned in the notification). A usage-limit requeue never pushes: it resets the branch to where the round started. Fix rounds only continue `agent/*` branches.

```bash
MERGE_THRESHOLD=90   # minimum PM confidence (%) for READY
MAX_FIX_ROUNDS=2     # fix rounds per PR before it goes to a human
AUTO_MERGE=0         # reserved: 1 only prints "auto-merge is not enabled yet"
PM_TIMEOUT=900       # max seconds for the PM agent
PM_PERMISSION_MODE=auto  # permission mode for the PM (bypassPermissions is never used)
PM=0 bin/farm.sh     # skip the project-manager step
bin/pm.sh tasks/done/<id>.md   # run it by hand on a finished task (needs pr: in its frontmatter)
```
PM replies are saved as `logs/<id>.pm-r<round>.md`. Every notification is appended to `logs/notifications.log`; email is optional.

**One-time email setup (Gmail):**
1. `sudo apt install msmtp msmtp-mta`
2. Create a Gmail App Password at https://myaccount.google.com/apppasswords (it needs 2-Step Verification). Store it:
   ```bash
   mkdir -p ~/.config/msmtp && nano ~/.config/msmtp/gmail.pass && chmod 600 ~/.config/msmtp/gmail.pass
   ```
3. Create `~/.msmtprc` (then `chmod 600 ~/.msmtprc`):
   ```
   defaults
   auth           on
   tls            on
   tls_trust_file /etc/ssl/certs/ca-certificates.crt
   logfile        ~/.msmtp.log

   account        gmail
   host           smtp.gmail.com
   port           587
   from           you@gmail.com
   user           you@gmail.com
   passwordeval   "cat ~/.config/msmtp/gmail.pass"

   account default : gmail
   ```
4. `cp .env.example .env`, then set `NOTIFY_EMAIL` (and optionally `NOTIFY_ON`, `MSMTP_ACCOUNT`). `.env` is git-ignored.
   - **Recognise farm emails at a glance:** they arrive from the sender name **"Agent Farm"** (`NOTIFY_FROM_NAME`) with subjects starting `[agent-farm]`. Using a Gmail +alias as `NOTIFY_EMAIL` (for example `you+agentfarm@gmail.com`) also lets you add a Gmail filter on `to:you+agentfarm@gmail.com` that labels or stars them. The sender address defaults to `NOTIFY_EMAIL` without the `+tag` (your Gmail account); override it with `NOTIFY_FROM`.
5. Test: `echo hello | bin/notify.sh ready "test" -`

Without msmtp or `NOTIFY_EMAIL`, notifications are only logged, with the warning "email not configured: see README".

## Monitor
```bash
bin/watch.sh        # live view, refreshes every 5 s (Ctrl+C to exit); bin/watch.sh 2 for every 2 s
node bin/watch.js   # print once
```
Under the header, a usage line shows the last plan-usage reading and the limits: `usage  5h 42% (resets 18:10) · week 25% (resets Thu 21:00) · limits 75% / 90% · checked 3m ago`. A percentage is yellow within 10 points of its limit and red at or over it. A reading older than 2 × `USAGE_MAX_AGE` is marked `(stale)`, and without `state/usage.json` it shows `usage  unknown (run bin/usage.sh)`. `bin/watch.sh` refreshes the reading in the background every `WATCH_USAGE_REFRESH` seconds (default 600, `0` disables it) with `bin/usage.sh --refresh`, quietly and never two at once; each refresh is a probe and costs a tiny amount of quota. `node bin/watch.js` alone never probes.

For each running task it shows how long it has been running, the agents called so far (`coder → tester → reviewer`), which agent is active right now, and its last action (the file it's reading, the command it's running). It also shows the queue size, any usage-limit pause, and the last 5 finished tasks with their PR links.
- A **red dot** means the runner process died (crash or kill). Check `logs/<id>.err`.
- **⚠ no activity for Xm** appears after 10 minutes with no activity (`STALE_MINUTES` changes this): either stuck, or waiting on a long command.
- **Interactive sessions** lists Claude sessions you started yourself (for example `claude --agent orchestrator` in a project), which the runner doesn't record. It shows sessions whose transcript changed in the last 15 minutes (`ACTIVE_MINUTES` changes this), most recent first, at most 8: the project path, the session's agent (`--agent <name>`, or "main session"), the subagent that is working right now (`orchestrator → tester`), its last action, and the time since the last activity. Sessions idle for more than 5 minutes are dimmed. Farm runs (projects under `worktrees/`) are left out because they are already shown above. The session you are watching from may appear too. So may a project-manager run (`bin/pm.sh`) when the branch has no worktree and it runs in the repo itself: it shows up briefly as a "main session" while it works. The header also counts them: `running N   queued N   interactive N`.
- `CLAUDE_PROJECTS_DIR` points it at another transcripts folder (default `~/.claude/projects`), which is useful for testing.
- `watch.js` only reads local files and makes no API calls, so it doesn't use your Pro limits (the background usage refresh in `watch.sh` is the one exception, see above). For interactive sessions it only reads transcripts changed within `ACTIVE_MINUTES`, and only their last 256 KB.

## Status (for a dashboard, Linear or a database later)
Every state change is recorded by `bin/status.js`:
- `state/events.jsonl`: an append-only event log (`started`, `done`, `failed`, `requeued`, `cleaned`, `pm_decision`, `pm_fix`, `notified`, `notify_failed`, `usage`, `usage_pause`, `restacked`)
- `state/status.json`: a snapshot with the machine, the number of running agents, and each task's state and PR
- `STATUS_HOOK='my-sync-script'`: run for every event, with the event JSON on stdin. This is where a Linear, database or webhook adapter plugs in.

`node bin/status.js show` prints the current state.

## Safety
- Runs use `PERMISSION_MODE=auto`, which blocks risky commands automatically. Use `bypassPermissions` only inside a Docker container.
- Nothing merges automatically. In farm runs agents never push; only the script pushes, and only to its own `agent/*` branch (fix rounds push to the PR's existing branch). An interactive orchestrator pushes only its own feature branch and opens a PR. The project manager only comments. You merge.

## TODO
- **Record interactive sessions as status events (option 2).** The monitor finds interactive sessions by scanning transcripts, so they never reach `state/events.jsonl`, `state/status.json` or `STATUS_HOOK` (and so not the future online dashboard in Linear or a database). Claude Code hooks could fix that: `SessionStart` and `SessionEnd` (and optionally `SubagentStart` / `SubagentStop`) in `~/.claude/settings.json`, each calling `bin/status.js` with the hook's JSON (session id, cwd, agent). You have to edit `~/.claude/settings.json` yourself, because Claude can't change its own settings. To decide first:
  - Event names, for example `session_started` / `session_ended` / `subagent_started` / `subagent_stopped`, and whether they share the task schema in `status.json` or get their own `sessions` key.
  - Whether to track subagents, or only the main session (fewer events, less noise).
  - How to label sessions: project path, `--agent` name, session id, or the session title.
  - Whether to skip farm runs (`worktrees/`) in the hook, since the runner already records them.
