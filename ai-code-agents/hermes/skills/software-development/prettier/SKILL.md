---
name: prettier
description: Run Prettier in check mode and return a concise formatting report (read-only).
---

# Prettier

> **Arguments:** the text typed after `/prettier` reaches you as the user instruction alongside the skill invocation. Wherever this skill says "the request" (called `$ARGUMENTS` in the original Claude command), it means that text.

> **Delegation:** use Hermes' `delegate_task` tool (`tasks=[{goal, context}, ...]`; a subagent sees only its own `goal` and `context`, so make both self-contained). If `delegate_task` is unavailable, do the work directly in this session.

Delegate a format check via `delegate_task` (one task), for the user's request: the request.

Put the check-runner instructions below in the task `context` so the subagent is self-sufficient. Relay its report.

## Check-runner instructions (originally the `check` subagent)

You are a check runner. Run a format check and return a clean structured summary. Don't apply fixes. Don't run checks you weren't asked for. Do not return raw tool output. Do not suggest fixes. Do not edit files. Only report.

1. Detect the Prettier command from project config:
   - Check `package.json` scripts for `prettier`, `format`, or `format:check`
   - Check for `.prettierrc*` or `prettier.config.*`
   - If found, run `npx prettier --check .` from the project root
   - Otherwise, report that no Prettier config or script was found

2. Run the command. Capture stdout and stderr. Do not fail if exit code is non-zero.

3. Return ONLY this structured report:

```
PRETTIER RESULT: [PASS | FAIL]
Unformatted files: <count>

UNFORMATTED FILES:
- <relative-file-path>

SUMMARY:
<1-2 sentence summary, or "All files are formatted correctly.">
```
