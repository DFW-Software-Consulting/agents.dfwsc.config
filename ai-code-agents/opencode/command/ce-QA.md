---
description: READ-ONLY QA focused on code-logic correctness of recent changes. No coding, no edits, no fixes.
---

# QA (Read-Only) — Code Logic First

Run a post-execution QA review for: $ARGUMENTS (topic OR path to plan/report)

## Strict Ordering
1) Locate artifacts -> 2) Build change set -> 3) Code-logic review -> 4) Tests & contracts review -> 5) Secondary scans (optional) -> 6) Synthesize findings -> 7) Save QA report

## Step 1 — Locate Inputs
- Resolve target by $ARGUMENTS (path or topic).
- Read fully: Plan, Execution Log, Execution Report.

## Step 2 — Build the Change Set (read-only)
- Determine commit range (start from plan/log if available, end at HEAD).
- Capture: `git diff --name-status`, `git diff --stat`, `git log --oneline` for the range.
- Extract changed files, group by module/package.

## Step 3 — Code-Logic Review (PRIMARY)
Checklist per changed module/file/function:
- **Inputs & Preconditions**: validation, type assumptions, boundary values.
- **Control Flow**: branching completeness, unreachable paths, early returns.
- **Data Flow**: invariant preservation, mutation scope, shared state leakage.
- **State & Transactions**: idempotency, atomicity, race/concurrency hazards.
- **Error Handling**: specific vs broad catches, retry/backoff, dead-letter paths.
- **Contracts**: pre/post-conditions, schema compatibility, versioning.
- **Resource Hygiene**: file/conn lifecycle, timeouts, cancellation propagation.
- **Edge Cases**: empty sets, max sizes, pagination, partial failure.

## Step 4 — Tests & Contracts (READ-ONLY)
- Map changed public functions/endpoints to test coverage.
- Identify missing cases: error branches, boundary conditions.

## Step 5 — Secondary Scans (Optional, Read-Only)
- Static/security summaries (no write/auto-fix).

## Step 6 — Write QA Report
Create `memory-bank/QA/YYYY-MM-DD_HH-MM-SS_<topic>_qa.md`:

### 0. Summary Verdict
- Overall: Accept | Accept w/ Conditions | Reject
- Top logic risks (3-5 bullets)

### 1. Change Summary
- Commit range, diffstat, modules touched.

### 2. Code-Logic Findings (by severity)
- Evidence (file:lines, commit), Impact, Likelihood, Suggested Remediation (outline only).

### 3. Test Coverage Gaps

### 4. Secondary Scan Results

## Hard Guards
- Do not modify source files.
- Do not create commits/branches/PRs.
- Produce findings and recommendations ONLY.
