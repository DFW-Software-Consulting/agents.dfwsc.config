---
description: Run the project's lint command in the check subagent and return a concise issue report.
agent: check
subtask: true
---

# Lint

Run a lint check for the user's request: `$ARGUMENTS`.

You are the `check` subagent. Do the following:

- Detect the project's lint command from package scripts or project docs.
- Run lint only; do not edit files unless the user explicitly asked for fixes.
- Return a concise report with file, line, rule/code, and message when available.
- If lint cannot run, explain the missing command or dependency.
