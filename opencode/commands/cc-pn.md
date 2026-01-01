---
description: Generates a concrete implementation plan from a research doc, with milestones, tasks, gates
---

## Initial Setup (prompt)
"I'm ready to plan the work. Please provide either the path to the research document in memory-bank/research/ or a short topic to find it."

## Strict Ordering
1) Read research doc FULLY -> 2) Validate freshness -> 3) Plan milestones/tasks -> 4) Define gates/criteria -> 5) Persist plan

## Step 1 — Input & Context
- If path provided: Read FULL file (no offsets) from `memory-bank/research/`.
- If topic provided: grep/select the latest `memory-bank/research/*topic*.md` and read FULLY.
- Extract: scope, constraints, key files, unresolved questions, suggested solutions, references.

## Step 2 — Freshness & Diff Check
- Capture current git state (if git repository exists):
- Git branch: !`git branch --show-current`
- Git commit: !`git rev-parse --short HEAD`
- If code changed since research doc commit:
  - Append **"Drift Detected"** note and mark items requiring re-verification.

## Step 3 — Planning Decomposition
Create `memory-bank/plan/YYYY-MM-DD_HH-MM-SS_<topic>.md` with this exact structure:

```
---
title: "<topic> – Plan"
phase: Plan
date: "{{timestamp}}"
owner: "{{agent_or_user}}"
parent_research: "memory-bank/research/<file>.md"
git_commit_at_plan: "<short_sha>"
tags: [plan, <topic>]
---
```

## Goal
- Crisp statement of outcomes and non-goals.
- MOST IMPORTANT: Clarify the singular goal and focus on execution.

## Scope & Assumptions
- In / Out of scope
- Explicit assumptions & constraints

## Deliverables (DoD)
- Artifacts with measurable acceptance criteria (tests, docs, endpoints, CLIs, dashboards).

## Readiness (DoR)
- Preconditions, data, access, envs, fixtures required to start.

## Milestones
- M1: Architecture & skeleton
- M2: Core feature(s)
- M3: Tests & hardening
- M4: Packaging & deploy
- M5: Observability & docs

## Work Breakdown (Tasks)
- Task ID, summary, owner, estimate, dependencies, target milestone
- For each task: **Acceptance Tests** (bullet list), **Files/Interfaces** touched

## Risks & Mitigations
- Risk -> Impact -> Likelihood -> Mitigation -> Trigger

## Test Strategy
- At most ONE new test. If more tests are needed, defer to next cycle.

## References
- Research doc sections, GitHub permalinks, tickets

## Final Gate
- Output a short summary with: plan path, milestones count, gates, and next command hint: `/ce-ex "<plan_path>"`

- This must be a singular focused plan. We can have ONE alternative option in the same document but in general we MUST have a singular focused plan on execution.

DO NOT CODE. SAVE THE DOCUMENT IN THE CORRECT FORMAT FOR THE NEXT DEV. ALWAYS FOLLOW BEST PRACTICES.
