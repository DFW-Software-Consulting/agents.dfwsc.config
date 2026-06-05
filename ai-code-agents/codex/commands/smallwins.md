---
allowed-tools: Edit, View, Bash(git:*), Bash(python:*), Bash(pytest:*), Bash(mypy:*), Bash(black:*), Bash(coverage:*), Bash(mutmut:*), Bash(docker:*), Bash(trivy:*), Bash(hadolint:*), Bash(dive:*), Bash(npm:*), Bash(kubectl:*), Bash(helm:*), Bash(lighthouse:*), Bash(jq:*), Bash(curl:*), Bash(gh:*)
description: Generates a concrete implementation plan from a research doc, with milestones, tasks, gates
writes-to: memory-bank/qa/
---



# Find and document small wins for: $ARGUMENTS

> Scope: strictly detection + documentation. No edits, no refactors, no PRs.

## Context Gathering
* Repo snapshot: check git status, current branch, and latest commit hash to understand repository state
* Top languages / size: analyze file types by MIME type and count files per language to understand codebase composition
* Project roots: @README* @CONTRIBUTING* @.editorconfig @.gitignore @pyproject.toml @package.json @Cargo.toml @tsconfig.json
* Lint/setup hints:

  * Python: @pyproject.toml @ruff.toml @mypy.ini
  * TS/JS: @biome.json @eslint* @.eslintrc* @prettier*
  * Rust: @Cargo.toml @rust-toolchain*
* Test layout preview: discover test directory structures by finding directories named tests or __tests__ within four levels of depth

## Planning Note

Create `AUDIT_SMALL_WINS_PLAN.md` with: goals, constraints (read‑only), and categories to scan.

## Detection Passes (Read‑Only)

### A. Structure & Naming

* Directory oddities: identify directories with unusual naming patterns, inconsistent structures, or organizational anomalies
* Duplicate mini‑modules / dead folders: find empty directories and potential duplicate module structures that could be consolidated
* Misnamed files vs conventions (e.g., snake_case, kebab-case): detect files that violate language-specific naming conventions when compared to their language standards

### B. Dead Code & Orphans (heuristics)

* Unused Python symbols: identify Python functions and classes that are defined but never imported or called elsewhere in the codebase
* Exported‑but‑unused TS: find TypeScript exports that are declared but never imported by any other module
* Grep for TODO/FIXME debt: search for technical debt markers like TODO, FIXME, HACK, and XXX comments throughout the codebase
* Files not referenced: detect files that aren't imported, required, or referenced by any other files in the repository

### C. Lint & Config Drifts

* Python: run Python linter to detect code style violations, potential bugs, and configuration drift from project standards
* Types: execute type checker to find type errors, missing type annotations, and type-related inconsistencies
* JS/TS: run JavaScript and TypeScript linters to identify code quality issues, style violations, and best practice deviations

### D. Micro‑Performance/Clarity Hints

* Hot paths by size/complexity: identify frequently called functions and measure their complexity and size to spot potential optimization targets
* Long functions (>100 lines): find functions that exceed recommended length thresholds and may benefit from refactoring into smaller units

## Report Assembly (Single Artifact)

Create `reports/SMALL_WINS_AUDIT.md` with sections:

1. **Executive Summary (≤7 bullets)**

   * Top quick wins (rename, move, delete, config tidy) with estimated effort (XS/S) and impact (L/M/S).
2. **Findings by Category**

   * Structure/Naming
   * Dead Code/Orphans
   * Lint/Config Drifts
   * Tests (gaps, flaky patterns, missing fixtures dirs)
3. **Per‑File Suggestions (No Edits)**

   * `path/to/file`: issue → suggested action (one‑liner), risk, owner guess.
4. **Guardrails & Next Steps**

   * Batch into ≤30‑minute PRs, ≤10 files/PR, add tests where deletion occurs.

## Validation (Read‑Only)

* Sanity: verify the repository state is clean and check for uncommitted changes before starting the audit

## Success Criteria

* Report exists at `reports/SMALL_WINS_AUDIT.md`.
* ≤1 hour to implement first batch of wins.
* No modifications performed by this command.

YOU MUST DEPLOY THESE 3 IN PARELLEL
YOU WILL BE PUNISHED FOR NOT DEPLOYING SUBAGENT
**For codebase research:**
- Use the **codebase-locator** agent to find WHERE files and components live
- Use the **codebase-analyzer** agent to understand HOW specific code works
- Use the **context-synthesis** agent to find context as needed


## Notes

* Keep all tool invocations read‑only; accept non‑zero exits.
* Prefer deletion over addition in later PRs, but **this command documents only**.
* Target small, surgical improvements; defer architecture debates to a separate ticket.

