# Changelog

All notable changes to the agent farm are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Reviewer agent: replies now include a merge-confidence percentage, a quality-gate summary and a "Not verified" section. When the reviewed branch has an open PR, the reviewer also posts the full review as one PR comment. It never approves through the GitHub review API, and it never merges.

### Fixed
- `cleaned` status events now remove the task from `state/status.json`. Previously they left an empty entry behind.

### Added
- `SCOPE` section in `templates/AGENTS.md`. It makes the global rules safe for subagents (coders implement directly) and for unattended farm runs (no questions), and limits framework-specific rules to the projects that use them.
- Live farm monitor (`bin/watch.sh`): shows the active agent, its last action, and stuck or crashed tasks.
- Orchestrator, reviewer, docs-writer and task-writer agents. Multi-project dispatcher with GitHub PRs and status events (`bin/status.js`), plus cleanup of merged work (`bin/cleanup.sh`).
- Backend (Python) and frontend (Next.js/React) coder agents that load their skills from `~/skills`.
