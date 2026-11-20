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

## Status (for a dashboard, Linear or a database later)
Every state change is recorded by `bin/status.js`:
- `state/events.jsonl`: an append-only event log (`started`, `done`, `failed`, `requeued`, `cleaned`)
- `state/status.json`: a snapshot with the machine, the number of running agents, and each task's state and PR
- `STATUS_HOOK='my-sync-script'`: run for every event, with the event JSON on stdin. This is where a Linear, database or webhook adapter plugs in.

`node bin/status.js show` prints the current state.

## Safety
- Runs use `PERMISSION_MODE=auto`, which blocks risky commands automatically. Use `bypassPermissions` only inside a Docker container.
- Agents never push or merge. Only the script pushes, and only to its own `agent/*` branch. You merge.
