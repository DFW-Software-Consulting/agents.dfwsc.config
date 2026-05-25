---
name: biome-linter
description: Use when the user asks to run Biome, format code, organize imports, or apply safe lint fixes.
---

# Biome Autofix Linter

## Overview

Run Biome to lint, format, and organize imports. Apply **safe fixes** by default; allow **unsafe fixes** only when explicitly requested. Return a compact summary (files scanned/changed, error/warn counts) and any remaining diagnostics.

## When to Use

- The user asks to “fix linter issues,” “run Biome,” “format code,” or “organize imports.”
- A project root or subpath is provided (or obvious from context).
- CI pre-checks or local cleanup before committing or opening a PR.

## Inputs

- `root` (string; default `"."`): project root to run in.
- `paths` (array of globs/paths; optional): limit scope.
- `dry_run` (bool; default `false`): report only, do not write.
- `allow_unsafe` (bool; default `false`): permit unsafe fixes.

## Instructions for the Agent

- Ensure Biome is available in the environment; if not, request install guidance or exit with a helpful note.
- Work within `root`; if `paths` provided, operate on those, else `"."`.
- Prefer `biome check` for a full pass (lint + format + organize imports).
- Apply **safe fixes** by default with `--write`; if `dry_run=true`, omit `--write`.
- Only add `--unsafe` when `allow_unsafe=true`.
- If no config is present, run a non-destructive `biome init` to generate defaults, then proceed.
- After execution, parse CLI output to compute:

  - `files_scanned`, `files_changed`
  - counts of `errors`, `warnings`
  - unresolved diagnostics (file:line:col rule — message)

- If exit code indicates failures but fixes were applied, still return a structured summary and suggested next steps (e.g., rule adjustments, targeted refactors).

## Execution Plan

1. **Resolve scope**: set `cwd = root`; determine `<scope>` = `paths` or `"."`.
2. **Choose command**:

   - Safe fixes: `npx @biomejs/biome check --write <scope>`
   - Dry run: `npx @biomejs/biome check <scope>`
   - Unsafe (opt-in): `npx @biomejs/biome check --write --unsafe <scope>`

3. **Run & capture**: collect stdout/stderr and exit code.
4. **Summarize**: build the output JSON below and a brief human summary.
5. **Report**: include unresolved diagnostics and next steps; if nothing remains, confirm clean state.

## Output (return this JSON object)

```json
{
  "status": "success|needs_input|blocked",
  "summary": "string",
  "stats": {
    "files_scanned": 0,
    "files_changed": 0,
    "errors": 0,
    "warnings": 0
  },
  "remaining_diagnostics": [
    {
      "file": "string",
      "line": 0,
      "col": 0,
      "rule": "string",
      "message": "string"
    }
  ],
  "next_steps": ["string"]
}
```

## Safety & Limits

- Modify only files within `root`/`paths`.
- Never store or request secrets.
- Use `--unsafe` **only** when `allow_unsafe = true`.
- If Biome is missing or the environment cannot install packages, return `needs_input` with clear install instructions.
