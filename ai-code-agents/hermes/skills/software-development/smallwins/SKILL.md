---
name: smallwins
description: Read-only audit that finds small, low-risk cleanup wins and writes a report to reports/SMALL_WINS_AUDIT.md.
---

> **Arguments:** the text typed after `/smallwins` reaches you as the user instruction alongside the skill invocation. Wherever this skill says "the request" (called `$ARGUMENTS` in the original Claude command), it means that text.

# Find and document small wins for: the request

> Scope: strictly detection + documentation. No edits, no refactors, no PRs.

## Context Gathering
* Repo snapshot: check git status, current branch, and latest commit hash to understand repository state
* Top languages / size: analyze file types by MIME type and count files per language to understand codebase composition
* Project roots (read whichever exist): README*, CONTRIBUTING*, .editorconfig, .gitignore, pyproject.toml, package.json, Cargo.toml, tsconfig.json
* Lint/setup hints:

  * Python: pyproject.toml, ruff.toml, mypy.ini
  * TS/JS: biome.json, eslint*, .eslintrc*, prettier*
  * Rust: Cargo.toml, rust-toolchain*
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

Run locator, analyzer, and context-synthesis subagents in parallel, in a single `delegate_task` call (three entries in `tasks`).
**For codebase research** (Hermes has no named agent types; put the role text from "Subagent roles" below in each task):
- **locator**: find WHERE files and components live
- **analyzer**: understand HOW specific code works
- **context-synthesis**: find context as needed


## Notes

* Keep all tool invocations read‑only; accept non‑zero exits.
* Prefer deletion over addition in later PRs, but **this command documents only**.
* Target small, surgical improvements; defer architecture debates to a separate ticket.

Use the `terminal` tool for shell commands (git, python, pytest, mypy, npm, etc.; run only what exists in the project), `read_file`/`search_files` for reading, and `write_file` only for `AUDIT_SMALL_WINS_PLAN.md` and `reports/SMALL_WINS_AUDIT.md`.


## Subagent roles (carried over from the Claude `codebase-locator`, `codebase-analyzer`, `context-synthesis` agents)

All three are read-only: they only read and search (`read_file`, `search_files`), never edit, never suggest changes.

**locator** — Your only job is to find WHERE things live. Given a topic, component, or pattern: (1) search for matching files and directories; (2) map the directory structure relevant to the topic; (3) identify entry points, index files, and key modules; (4) note file paths with line numbers where relevant. Output a structured list of file paths and their purpose, directory layout for the relevant area, and entry points and how they connect. Do not analyze implementation details.

**analyzer** — Your only job is to understand HOW code works. Given a file, component, or topic: (1) read the relevant files fully; (2) map function signatures, class hierarchies, and interfaces; (3) trace data flow through the component; (4) identify dependencies; (5) note key patterns and implementation decisions. Output a structured analysis: what the code does and how, key functions/classes with signatures, data flow and transformations, internal dependencies, exact file paths and line numbers for all findings. Do not suggest improvements.

**context-synthesis** — Your job is to find connections and gather surrounding context. Given two or more areas, a topic, or a question about relationships: (1) trace how components depend on each other; (2) find shared patterns across modules; (3) identify cross-cutting concerns (auth, logging, error handling, etc.); (4) map what imports what and how data flows between modules; (5) surface shared types, constants, or utilities. Output relationships (A -> imports -> B), shared patterns and where they appear, cross-cutting concerns and how they are handled, and context that connects the findings.
