---
description: Generates an execution-ready, coding-only implementation plan from a research doc; verifies git freshness.
---

# Plan from Research

Generate an execution-ready implementation plan focused solely on **technical coding work** from a given research document.

## Plan Rules

1. **Input & Context**
   - Read the research doc fully (from `memory-bank/research/` or matching topic).
   - Extract: scope, coding constraints, target files/modules, unresolved questions, proposed solutions.

2. **Freshness Check**
   - Git branch: !`git branch --show-current`
   - Git commit: !`git rev-parse --short HEAD`
   - If drift is detected between doc and repo, mark items for re-verification.

3. **Plan Output File**
   Save as: `memory-bank/plan/YYYY-MM-DD_HH-MM-SS_<topic>.md`

   Structure:
   - **Goal** - ONE singular coding-focused outcome. Non-goals.
   - **Scope & Assumptions** - In/out of scope (technical only).
   - **Deliverables** - Source code modules, functions, or APIs.
   - **Readiness** - Preconditions (repos, libs, data schemas).
   - **Milestones** - M1: Skeleton, M2: Core logic, M3: Feature completion, M4: Tests.
   - **Work Breakdown** - Task ID, summary, acceptance test (max 1 per task), files touched.
   - **Risks & Mitigations** - Risk -> Impact -> Likelihood -> Mitigation -> Trigger
   - **Test Strategy** - At most ONE new test per task. Defer extras to next cycle.
   - **References** - Research doc sections, key code refs.
   - **Final Gate** - Plan path, milestone count, next command hint: `/ce-ex "<plan_path>"`.

4. **North Star Rule** - A developer must be able to start coding immediately with zero ambiguity.

This must be a singular focused plan. ONE alternative option allowed but execution must be singular.

DO NOT CODE. SAVE THE DOCUMENT IN THE CORRECT FORMAT. ALWAYS FOLLOW BEST PRACTICES.
