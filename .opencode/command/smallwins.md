---
description: Find and document small wins - detection and documentation only, no edits
---

# Find and document small wins for: $ARGUMENTS

> Scope: strictly detection + documentation. No edits, no refactors, no PRs.

## Context Gathering

- Repo snapshot: !`git status --short` and !`git log --oneline -3`
- Top languages / size: analyze file types and count files per language
- Project roots: check README, package.json, pyproject.toml, Cargo.toml, tsconfig.json
- Lint/setup hints:
  - Python: pyproject.toml, ruff.toml, mypy.ini
  - TS/JS: biome.json, eslint config, prettier config
  - Rust: Cargo.toml, rust-toolchain
- Test layout preview: discover test directory structures

## Planning Note

Create `AUDIT_SMALL_WINS_PLAN.md` with: goals, constraints (read-only), and categories to scan.

## Detection Passes (Read-Only)

### A. Structure & Naming
- Directory oddities: unusual naming patterns, inconsistent structures
- Duplicate mini-modules / dead folders: empty directories, potential duplicates
- Misnamed files vs conventions (snake_case, kebab-case)

### B. Dead Code & Orphans (heuristics)
- Unused symbols: functions/classes defined but never imported or called
- Exported-but-unused: exports that are never imported elsewhere
- Grep for TODO/FIXME debt: technical debt markers throughout the codebase
- Files not referenced: files not imported or referenced by any other files

### C. Lint & Config Drifts
- Python: run linter to detect style violations and potential bugs
- Types: execute type checker to find type errors and missing annotations
- JS/TS: run linters for code quality issues and style violations

### D. Micro-Performance/Clarity Hints
- Hot paths by size/complexity: frequently called functions, complexity metrics
- Long functions (>100 lines): functions that may benefit from splitting

## Report Assembly (Single Artifact)

Create `reports/SMALL_WINS_AUDIT.md` with sections:

1. **Executive Summary (<=7 bullets)** - Top quick wins with effort (XS/S) and impact (L/M/S).
2. **Findings by Category** - Structure/Naming, Dead Code/Orphans, Lint/Config Drifts, Tests.
3. **Per-File Suggestions (No Edits)** - `path/to/file`: issue -> suggested action, risk.
4. **Guardrails & Next Steps** - Batch into <=30-minute PRs, <=10 files/PR.

## Success Criteria

- Report exists at `reports/SMALL_WINS_AUDIT.md`.
- No modifications performed by this command.
- Target small, surgical improvements; defer architecture debates to a separate ticket.
