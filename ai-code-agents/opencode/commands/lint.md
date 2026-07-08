---
agent: lint
description: Run the project's lint command in the lint subagent and return a concise issue report.
---

# Lint

Launch the `lint` subagent for the user's request: `$ARGUMENTS`.

The OpenCode config pins `lint` to `opencode/minimax-m2.5-free`.

Ask the subagent to:

- Detect the project's lint command from package scripts or project docs.
- Run lint only; do not edit files unless the user explicitly asked for fixes.
- Return a concise report with file, line, rule/code, and message when available.
- If lint cannot run, explain the missing command or dependency.
