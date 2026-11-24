# CRITICAL RULES - MUST FOLLOW

## SCOPE

- These rules are written for the main session working with a human.
- If you are a subagent with a defined role (coder, tester, reviewer, docs-writer), your role instructions take precedence where they conflict. Coders implement directly; only the main session delegates.
- In unattended runs (the task starts with `MODE: unattended`), never ask questions: make the most reasonable decision and record it in your report.
- Framework-specific rules (Drizzle, `next build`, DESIGN.md) apply only to projects that use them.

## RESPONSES

- Keep responses concise and to the point - unless the user asks otherwise

## PLANNING MODE

- Always ask clarifying questions
- Never assume design, tech stack or features
- Use deep-dive sub-agents to assist with research
- Use deep-dive sub-agents to review the different aspects of your plan before presenting to the user

## CHANGE / EDIT MODE

- Never implement features yourself when possible - use sub-agents!
- Identify changes from the plan that can be implemented in parallel, and use sub-agents to implement the features efficiently
- When using sub-agents to implement features, act as a coordinator only
- Use the best model for the task - premium models for complex tasks (like coding) and mid-tier models for simpler tasks, like documentation
- After completing features (large or small), always run commands like lint, type check and next build to check code quality
- Always add doc block comments to functions so they can be turned into documentation. For complex functions, also add one-line explanations in the code itself.
- Any changes should be made on their own branches and reviewed either by the human or the code review agent before being merged into the master branch.
- Every change should be accompanied by an update to the project's changelog.md (if it does not have a changelog.md file, create one)
- Push the branch and open a pull request on GitHub for review (a draft if the review did not pass). Never merge it yourself — the human merges.

## DATABASE SCHEMA CHANGES

- Whenever you make changes to the database schema, ALWAYS run the drizzle generate and migrate commands
- NEVER run drizzle push!

## TESTING

- Use any testing tools, libraries available to the project for testing your changes
- Never assume your changes simply work, always test!
- If the project does not have any testing tools, scripts, MCP tools, skills, etc. available for testing, ask the user whether testing should be skipped.

## UI DESIGN

- Always follow the UI design system when creating or reviewing components or pages.
- Design System: @DESIGN.md
