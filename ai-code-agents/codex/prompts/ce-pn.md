---
description: "Generates an execution-ready, coding-only implementation plan from a research doc; verifies git freshness; writes plan to memory-bank/plan/."
---
### Instruction

Your task is to generate an execution-ready implementation plan focused solely on **technical coding work** from a given research document.
You MUST ensure the output provides developers with everything they need to build directly, without drowning in secondary operational concerns like deployment, observability, or excessive testing.

### Plan Rules

1. **Input & Context**

   - Read the research doc fully (from `memory-bank/research/` or matching topic).
   - Extract: scope, coding constraints, target files/modules, unresolved technical questions, proposed solutions.

2. **Freshness Check**

   - Capture current git state (commit SHA + status).
   - If drift is detected between doc and repo, mark items for re-verification.

3. **Plan Output File**
   Save as: `memory-bank/plan/YYYY-MM-DD_HH-MM-SS_<topic>.md`

   Structure:

   ```markdown
   ---
   title: "<topic> – Plan"
   phase: Plan
   date: "{{timestamp}}"
   owner: "{{agent_or_user}}"
   parent_research: "memory-bank/research/<file>.md"
   git_commit_at_plan: "<short_sha>"
   tags: [plan, <topic>, coding]
   ---

   ## Goal

   - ONE singular coding-focused outcome.
   - Non-goals (explicitly exclude ops/deploy overhead).

   ## Scope & Assumptions

   - In / Out of scope (technical only).
   - Assumptions on frameworks, environments, or libraries.

   ## Deliverables

   - Source code modules, functions, or APIs.
   - Documentation limited to developer-level notes.

   ## Readiness

   - Preconditions (repos, libs, data schemas, sample inputs).

   ## Milestones

   - M1: Skeleton & architecture setup
   - M2: Core logic & data flow
   - M3: Feature completion & refinement
   - M4: Basic test(s) & integration hooks

   ## Work Breakdown (Tasks)

   - Task ID, summary, owner, estimate, dependencies, target milestone
   - Each task MUST list:
     - Acceptance test(s) (max 1 per task).
     - Files/modules touched.

   ## Risks & Mitigations

   - Keep technical: library stability, API version drift, schema mismatch.

   ## Test Strategy

   - At most ONE new test per task, only for validation of main coding work.

   ## References

   - Research doc sections, key code refs.

   ## Final Gate

   - Output summary: plan path, milestone count, tasks ready for coding.
   - Next command hint: `/execute "<plan_path>"`.
   ```

4. **Agents**

   - Max 1 at only if neede in general trust the research.

     - context-synthesis (doc → coding tasks)
     - codebase-analyzer (map tasks to files)

5. **North Star Rule**

   - If a developer picked this up, they must be able to **start coding immediately** with zero ambiguity.
