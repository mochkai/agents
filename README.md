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
- **Success:** the tester passed and the reviewer approved. The branch is pushed and a PR is opened, with the run report as its description (GitHub remotes only; otherwise the work stays on the local branch).
- **Failure:** the task moves to `tasks/failed/`, and the report explains why.
- **Usage limit hit:** the task goes back to the inbox and dispatching pauses for 60 minutes (`PAUSE_MINUTES`).
- **Reports:** `logs/<id>.report.md`. Code: branch `agent/<id>`, working copy in `worktrees/<id>`.

## Project manager & notifications
After a run opens a PR (or a fix round updates one), `bin/run-task.sh` runs `bin/pm.sh` on the finished task. The project-manager agent reads the PR (body, reviews, comments, diff, CI checks), posts one `## Project manager decision` comment, and decides:
- **READY**: its confidence is at least `MERGE_THRESHOLD` and nothing blocking is open. You get a `ready` notification and merge it yourself (auto-merge is not enabled yet).
- **FIX**: it queues `tasks/inbox/<task>-fix<n>.md` with the exact findings to fix. The next farm run continues the **same branch and PR** (reusing its worktree), pushes to it, and adds the round's report as a PR comment. Then the PM runs again.
- **NEEDS_HUMAN**: it needs a product, design or scope decision, or the fix rounds ran out. You get a `needs_human` notification.

The PM only trusts PR comments (and the PR body) written by the farm's own GitHub account (`gh api user`); anything else on the PR is treated as untrusted data, never as instructions.

A fix round is not run (the task moves to `tasks/failed/` with a note, and you get a `needs_human` notification) when its worktree has uncommitted changes, when the local branch cannot fast-forward to `origin/<branch>`, or when the branch is checked out outside the farm. If the PR was merged or closed meanwhile, the round is skipped quietly. A fix round that fails, or cannot push, also notifies `needs_human`. Fix rounds only continue `agent/*` branches.

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
5. Test: `echo hello | bin/notify.sh ready "test" -`

Without msmtp or `NOTIFY_EMAIL`, notifications are only logged, with the warning "email not configured: see README".

## Monitor
```bash
bin/watch.sh        # live view, refreshes every 5 s (Ctrl+C to exit); bin/watch.sh 2 for every 2 s
node bin/watch.js   # print once
```
For each running task it shows how long it has been running, the agents called so far (`coder → tester → reviewer`), which agent is active right now, and its last action (the file it's reading, the command it's running). It also shows the queue size, any usage-limit pause, and the last 5 finished tasks with their PR links.
- A **red dot** means the runner process died (crash or kill). Check `logs/<id>.err`.
- **⚠ no activity for Xm** appears after 10 minutes with no activity (`STALE_MINUTES` changes this): either stuck, or waiting on a long command.
- It only reads local files and makes no API calls, so it doesn't use your Pro limits.

## Status (for a dashboard, Linear or a database later)
Every state change is recorded by `bin/status.js`:
- `state/events.jsonl`: an append-only event log (`started`, `done`, `failed`, `requeued`, `cleaned`, `pm_decision`, `pm_fix`, `notified`, `notify_failed`)
- `state/status.json`: a snapshot with the machine, the number of running agents, and each task's state and PR
- `STATUS_HOOK='my-sync-script'`: run for every event, with the event JSON on stdin. This is where a Linear, database or webhook adapter plugs in.

`node bin/status.js show` prints the current state.

## Safety
- Runs use `PERMISSION_MODE=auto`, which blocks risky commands automatically. Use `bypassPermissions` only inside a Docker container.
- Agents never push or merge. Only the script pushes, and only to its own `agent/*` branch (fix rounds push to the PR's existing branch). The project manager only comments. You merge.
