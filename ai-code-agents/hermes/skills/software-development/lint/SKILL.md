---
name: lint
description: Run the project's lint command and return a concise issue report (read-only, no fixes unless asked).
---

# Lint

> **Arguments:** the text typed after `/lint` reaches you as the user instruction alongside the skill invocation. Wherever this skill says "the request" (called `$ARGUMENTS` in the original Claude command), it means that text.

> **Delegation:** use Hermes' `delegate_task` tool (`tasks=[{goal, context}, ...]`; a subagent sees only its own `goal` and `context`, so make both self-contained). If `delegate_task` is unavailable, do the work directly in this session.

Delegate a lint check via `delegate_task` (one task), for the user's request: the request.

Ask the subagent to:

- Detect the project's lint command from package scripts or project docs.
- Run lint only; do not edit files unless the user explicitly asked for fixes.
- Return a concise report with file, line, rule/code, and message when available.
- If lint cannot run, explain the missing command or dependency.

Put the check-runner instructions below in the task `context` so the subagent is self-sufficient. Relay its report.

## Check-runner instructions (originally the `check` subagent)

You are a check runner. Run the project's lint command and return a clean structured summary: pass/fail plus concise diagnostics. Don't apply fixes. Don't run checks you weren't asked for. Do not return raw tool output. Do not suggest fixes. Do not edit files. Only report.

1. Detect the lint command from project config:
   - Check `package.json` scripts for `lint`, `lint:check`, `lint:ci`
   - Check for `.eslintrc*`, `eslint.config.*` -> run `npx eslint .`
   - Check for `biome.json` -> run `npx @biomejs/biome check .`
   - Check for `ruff.toml` or `pyproject.toml` (ruff) -> run `ruff check .`
   - Check for `Cargo.toml` -> run `cargo clippy`
   - Fall back to `npm run lint` if `package.json` exists

2. Run the command. Capture stdout and stderr. Do not fail if exit code is non-zero.

3. Return ONLY this structured report:

```
LINT RESULT: [PASS | FAIL]
Errors:   <count>
Warnings: <count>

TOP ERRORS (max 20):
- <file>:<line>:<col> — <rule> — <message>

SUMMARY:
<1-2 sentence summary of what needs fixing, or "No lint issues found.">
```
