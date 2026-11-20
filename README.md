# Agent farm

Autonomous coding team built on the Claude Code CLI (Pro subscription).

```
task ──► orchestrator ──► coder ──► tester ──(fail? back to coder, max 3 rounds)──► commit on agent/<id> branch
```

## Run
Queue a task by writing a markdown file in `tasks/inbox/`, describing what to build and the acceptance criteria.

```bash
bin/farm.sh ~/path/to/repo        # process the inbox, 2 agents in parallel
bin/farm.sh ~/path/to/repo 1      # one at a time (gentlest on Pro limits)
bin/run-task.sh ~/repo task.md    # run a single task file directly
MODEL=opus bin/farm.sh ~/repo     # stronger model for hard tasks (uses more quota)
```

## Results
- `logs/<id>.report.md`: the orchestrator's report (STATUS line, summary, tests, follow-ups)
- `tasks/done/` and `tasks/failed/`: finished tasks
- Code: branch `agent/<id>` in the target repo; the working copy is at `worktrees/<id>`

Merge the work and clean up:
```bash
git -C ~/repo merge agent/<id>
git -C ~/repo worktree remove ~/agents/worktrees/<id>
git -C ~/repo branch -d agent/<id>
```

## Customize
- `prompts/orchestrator.md`: process and hard rules (no push, no merge, etc.)
- `agents/*.md`: subagents. Add a file such as `reviewer.md` with `description:` frontmatter to add a role, then mention it in the orchestrator prompt.

## Skills
Skills come from `~/skills` (a separate repo, loaded as the `my-skills` plugin). To preload skills into a role, add `skills: name1, name2` to that agent's frontmatter in `agents/*.md`.

## Safety
Runs use `PERMISSION_MODE=auto`: risky commands are blocked automatically. Only use `bypassPermissions` inside a Docker container.
