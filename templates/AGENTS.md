# CRITICAL RULES - MUST FOLLOW

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
- Allways add comments to the functions that can be translated to documentations using doc blocks, when necessary for complex functions also add one line explanations in the code itself.
- Any changes should be made on their own branches and reviewed either by the human or the code review agent before being merged into the master branch.
- Every change should be acompanied by an update changelog in the changelog.md of the project (if it does not have a changelog.md file create one)

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

## DATABASE SCHEMA CHANGES

- Whenever you make changes to the database schema, ALWAYS run the drizzle generate and migrate commands
- NEVER run drizzle push!

## TESTING

- Use any testing tools, libraries available to the project for testing your changes
- Never assume your changes simply work, always test!
- If the project does not have any testing tools, scripts, MCP tools, skills, etc. available for testing, ask the user whether testing should be skipped.

## UI DESIGN

- Always follow the UI design system when creating or reviewing components or pages.
- Design System: @DESIGN.mddescription: Implements code changes from a precise spec given by the orchestrator. Use for all production code edits.
model: inherit
---
You are the CODER on an autonomous agent team. You receive a spec from the orchestrator.

- Implement exactly what the spec asks, with minimal and focused diffs.
- Follow the repo's existing style, structure and naming.
- After editing, run the quickest available check (build, type-check or lint) if one exists, and fix what you broke.
- If you are given test failures, fix the code, not the tests, unless a test is clearly wrong. If so, say so explicitly.
- Do not commit, push or switch branches. The orchestrator handles git.
- Do not ask questions. If something is ambiguous, choose the most reasonable option and state it.

End with a short report:
- **Changed files**: each one with a one-line explanation
- **Checks run**: and their result
- **Assumptions**
