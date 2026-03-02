# AI-Assisted Development Workflow SOP

**Version:** 1.0  
**Status:** Active  
**Owner:** Engineering Lead / Tech Lead (TL)  
**Effective date:** 2026-02-24  
**Review cadence:** Every 7 days (or sooner if audits show drift)

---

## Purpose

Install **thinking discipline**, **verification discipline**, and **minimalism discipline** in AI-assisted development — **without increasing reviewer/lead workload**.

This SOP exists to prevent:

- Undefined work that invites AI guesswork
- Over-engineering and premature abstraction
- “Looks right” fixes that do not run
- Large diffs that are unreviewable and defect-prone

---

## Scope

Applies to:

- All production engineering work (features, bugfixes, refactors, infra)
- All AI-assisted coding and design work
- All teams unless explicitly exempted in writing by the Engineering Lead

---

## Non-goals

This SOP is **not** intended to:

- Ban AI usage
- Replace engineering judgement
- Mandate a specific toolchain or stack
- Add extra meetings

---

## Definitions

- **AI-assisted work:** Any work where an LLM or code-gen tool influenced design, implementation, tests, or documentation.
- **LOC (for PR policy):** Git hosting “lines changed” as displayed in the PR diff (additions + deletions).
  - If your platform reports “files changed / insertions / deletions,” use **insertions + deletions**.
  - Generated files and vendored code are still counted unless explicitly excluded by repo policy.
- **Gate:** A mandatory checkpoint with required artifacts and explicit approval before proceeding.

---

## Core Principles

1. **AI is a tool, not an authority.**
2. **If it does not run locally, it is not done.**
3. **If you cannot explain it, you do not understand it.**
4. **Simpler is preferred** unless complexity is explicitly justified.
5. **Small PRs are mandatory.**

---

## Lifecycle Model

All work moves through **four gates**. No skipping.

1. **Gate 1 — Issue Draft (Definition of Ready)**
2. **Gate 2 — Approach Approval**
3. **Gate 3 — Implementation**
4. **Gate 4 — Verification & Pull Request**

---

# Gate 1 — Issue Draft (Definition of Ready)

## Requirement

Before coding begins, the assigned engineer drafts the issue using the **Issue Template** below and requests approval.

**No code starts until Gate 1 is approved.**

## Issue Template

```text
Problem Statement:
Why this matters:
Reproduction Steps (if bug):
Expected Behavior:
Constraints (performance/security/backwards compatibility):
Acceptance Criteria:
Test Plan (how success will be validated):
```

## Approval

- **Approver:** peer reviewer or lead (team-dependent)
- **Approval signal:** explicit comment “Approved (Gate 1)” or equivalent

## Notes

- “Acceptance Criteria” must be objectively testable (not vibes).
- “Test Plan” must specify _how we will know it worked_ (unit tests, integration tests, manual steps, metrics).

---

# Gate 2 — Approach Approval

## Requirement

Before writing implementation code, the engineer posts an approach using the **Approach Template** below.

**No implementation begins until Gate 2 is approved.**

## Approach Template

```text
Files to be modified:
Core logic change:
Data flow impact:
Performance impact:
Simplest possible solution:
Alternative considered and rejected:
```

## Approval

- **Approver:** peer reviewer or lead (see “Peer Review Requirement”)
- **Approval signal:** explicit comment “Approved (Gate 2)”

## What gets rejected here

- New abstraction layers without necessity
- “Frameworking” a one-off change
- Data transformation chains without measurable need
- Any approach that cannot explain performance implications

---

# Gate 3 — Implementation Rules

AI usage is allowed, with strict constraints designed to prevent “outsourced understanding.”

## Before using AI

- Write your own rough approach first.
- Identify the expected _shape_ of the solution (inputs/outputs, failure modes, tests).

## After using AI

- Rewrite output in your own style (no blind copy/paste).
- Remove unnecessary abstraction.
- Verify locally (build + tests).
- Be able to explain every line.

**If you cannot explain a line, remove it or refactor until you can.**

## Data handling (baseline)

- Do not paste secrets, credentials, or customer data into unapproved tools.
- Use only AI tools/models approved by your org’s security policy.

---

# Gate 4 — Definition of Done (PR Requirements)

## Non-negotiable: No review without DoD

No PR will be reviewed unless the checklist and PR description requirements are complete.

## PR Template

### Verification Checklist

- [ ] Builds locally
- [ ] Tests pass (or explicitly stated none exist)
- [ ] Lint/typecheck passes
- [ ] Manually verified (describe steps)
- [ ] No unnecessary abstraction added
- [ ] Performance considered

### Required in PR description

- What changed and why
- Why this is the minimal solution
- How it was verified (commands + steps)
- Performance considerations (what you checked / why safe)

If missing → PR is returned without review.

---

# PR Size Policy (Enforced, Temporary Hard Cap)

## Policy

**Until we prove sustained consistency:**

- **Hard limit: 200 LOC per PR**
- Any PR **over 200 LOC** is **closed without review**
- No partial reviews
- No “just this once”
- No “review the important parts only”

This limit includes:

- Application code
- Tests
- Config / migrations
- Refactors

## What to do instead

If the change appears to require >200 LOC:

1. Split into a sequence of independently verifiable PRs.
2. Include a split plan (see template below) in the issue or approach.
3. Ship in increments.

## Split Plan Template

```text
Split plan:
PR 1: (smallest shippable step) — verification method:
PR 2: (next step) — verification method:
PR 3: (finish) — verification method:
Risks / rollback plan:
```

## How we lift the temporary hard cap

The lead may raise the cap only after **measurable consistency**. Default criteria:

- 4 consecutive weeks where:
  - ≥95% of merged PRs are ≤200 LOC
  - CI failures due to negligence are rare (tracked)
  - Random audit pass rate ≥90%

Until then, enforcement remains strict.

---

# Peer Review Requirement

## Standard changes

- **1 peer approval required** before merge.

## Lead review required for

- Architecture changes
- Performance-sensitive code
- Infra changes
- Core AI / platform systems
- Security-sensitive changes

Lead also performs random audits weekly.

---

# Failure Handling

If a PR:

- Does not run locally
- Breaks CI due to negligence
- Claims a fix but lacks verification evidence

Then:

- PR is marked **Draft** or **Closed**
- Author must fix and resubmit
- Repeat offenses are tracked (process issue, not personal)

## Closure comment template (mechanical enforcement)

```text
Closed per SOP: PR exceeds 200 LOC temporary hard cap.
Please split into sequential PRs ≤200 LOC each, each independently verifiable.
Include a split plan in the issue/approach. No review will be performed on this PR.
```

---

# Performance Guardrails

Prohibited **without explicit justification in the Approach**:

- New abstraction layers
- Data transformation chains
- Utility functions used once
- Nested loops without reasoning
- Catch blocks that silence errors
- “Retry forever” logic without bounds
- Logging that hides errors or drops context

Default stance: simplest correct implementation that meets constraints.

---

# Throughput Expectations

## Stabilization phase (first 4–6 weeks)

- 1 deep issue per engineer per week
- 1–2 mechanical issues per engineer per week
- Correctness over speed

After stability improves, volume may increase.

---

# Lead Load Protection

The lead does **not**:

- Fix code inside PRs
- Rewrite poorly designed solutions
- Approve work that fails DoD

The lead **does**:

- Approve issues (Gate 1)
- Approve approaches (Gate 2)
- Enforce gates
- Run random audits

This places the cognitive cost of sloppiness back on the author.

---

# Engineering Maturity Levels

## Level 1

- Requires strict gate enforcement
- Overuses AI (outsources understanding)
- Weak performance awareness

## Level 2

- Submits minimal, working PRs
- Rare architectural overreach
- Explains changes clearly
- Verifies locally and documents it

## Level 3

- Anticipates performance impact
- Designs clean approaches independently
- Uses AI as acceleration, not a crutch

Promotion / increased autonomy is tied to achieving Level 2 behavior.

---

# Cultural Standard (Leader Statement)

> AI is allowed. Sloppiness is not.  
> We prioritize correctness, clarity, and minimalism over volume.  
> If you cannot explain your code, it will not ship.

---

# Evidence and References (why small PRs are enforced)

This SOP intentionally aligns with evidence that **smaller, focused changes** improve review quality and reduce waste:

- Google’s engineering practices recommend small, self-contained changes and note that reviewers may reject changes solely for being too large.  
  https://google.github.io/eng-practices/review/developer/small-cls.html

- SmartBear summarizes findings (including a Cisco team study) that review effectiveness drops as the amount reviewed grows, and recommends reviewing **no more than ~200–400 LOC at a time**.  
  https://smartbear.com/learn/code-review/best-practices-for-peer-code-review/

- Microsoft research notes code review usefulness declines as the size of a review grows (e.g., more changed files reduces useful feedback), and highlights the real cost of long reviews and long review cycles.  
  https://www.microsoft.com/en-us/research/wp-content/uploads/2015/05/PID3556473.pdf

---

# Change Log

- **v1.0 (2026-02-24)** — Initial release. Introduces 4-gate workflow, enforced temporary 200 LOC hard cap, and DoD enforcement.
