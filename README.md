# Agents

A library of reusable Claude Code agent profiles and a shared rules template. There is no runner here: you drive the agents yourself from interactive Claude Code sessions (CLI, VS Code or the desktop app), and they work in any project.

```
claude --agent task-writer   ──► docs/tasks/<slug>.md (agreed spec)
claude --agent orchestrator  ──► backend-coder / frontend-coder / coder ──► tester ──► reviewer ──► docs-writer ──► commit ──► PR
                                 (fails or changes requested → back to the owning coder, max 3 rounds)
project-manager              ──► triages any PR: READY / FIX / NEEDS_HUMAN
```

## What's here
### Agent profiles (`agents/*.md`)
| Agent | Role | When to use | Skills it loads (`~/skills`) |
|---|---|---|---|
| `orchestrator` | plans with you, delegates, runs the test → review → fix loop, commits on a new branch, opens a PR | start a session with `claude --agent orchestrator` in a project (main session only) | none (each specialist loads its own) |
| `task-writer` | turns a rough idea into a precise spec in `docs/tasks/<slug>.md` | start a session with `claude --agent task-writer` before handing work to the orchestrator (main session only) | none |
| `project-manager` | reads a PR, its reviews and CI, and decides READY, FIX or NEEDS_HUMAN with a confidence and fix list; never merges | on any PR, as a subagent or a session | none |
| `backend-coder` | Python: ruff, mypy or pyright, pytest, docstrings | subagent for `.py` / backend work | always: verification-before-completion; when fixing bugs: systematic-debugging, diagnosing-bugs |
| `frontend-coder` | Next.js, React, TypeScript, accessibility | subagent for UI work | always: frontend-design, verification-before-completion; when fixing bugs: systematic-debugging |
| `coder` | everything else (other languages, config, infra) | subagent | always: verification-before-completion; when fixing bugs: systematic-debugging |
| `tester` | writes and runs tests, then reports PASS or FAIL | subagent after every coder round | always: test-driven-development, verification-before-completion; for web UI: webapp-testing |
| `reviewer` | read-only review: APPROVE or CHANGES REQUESTED, merge confidence, findings; comments on the PR if one exists | subagent after the tests pass | always: code-review-checklist |
| `docs-writer` | changelog.md and README (on Haiku) | subagent after the change is approved | none |

Nothing ever merges: the agents push at most their own feature branch and open a PR, and you merge.

### Rules template (`templates/AGENTS.md`)
Your global working rules (planning, branching, changelog, testing, UI design). Its SCOPE section makes them safe for subagents, which follow their role instructions where they conflict.

## Setup
Link the profiles into `~/.claude/agents/` so every Claude Code session (CLI, VS Code, desktop app) can use them:
```bash
mkdir -p ~/.claude/agents && ln -sfn ~/agents/agents/*.md ~/.claude/agents/
```
Load the rules globally by adding this line to `~/.claude/CLAUDE.md`:
```
@~/agents/templates/AGENTS.md
```

## Usage
- **Per project (optional):** copy `templates/AGENTS.md` into the project root and add a `CLAUDE.md` containing `@AGENTS.md`, so the rules travel with the repo and can be tuned for it.
- **Spec a task:** `claude --agent task-writer`, then agree the spec it saves to `docs/tasks/<slug>.md`.
- **Build it:** in the project, `claude --agent orchestrator` and ask it to implement the spec (or describe the task directly). It asks questions, plans, delegates, and ends with a PR link.
- **Delegate directly:** from any session, ask for a specific agent (for example "use the reviewer on this diff", or "run project-manager on PR 12").

## Skills
The agents read their skills from `~/skills` (the [skills repo](https://github.com/mochkai/skills)) when they start. A project skill with the same name in `.claude/skills/` wins.

code-factory (a separate repo, in progress) will reuse these profiles.
