---
name: coderabbit-fix
description: Take a CodeRabbit review on a GitHub PR and resolve it — fetch every CodeRabbit comment, extract its embedded "Prompt for AI Agents", fan out subagents that verify-then-fix each still-valid finding, validate, then optionally commit/push, reply, and drive CodeRabbit to a fresh Approve. Use when the user says things like "fix what CodeRabbit said", "address the CodeRabbit comments", "get CodeRabbit to approve this PR", or after pushing a branch that CodeRabbit reviewed.
---

# CodeRabbit Fix

Turn a CodeRabbit PR review into resolved code. CodeRabbit embeds a machine-readable
**"🤖 Prompt for AI Agents"** block in each finding — this skill harvests those prompts
and dispatches them to subagents, but never trusts them blindly.

## Core principle: verify before you fix

CodeRabbit is often right, sometimes stale, occasionally wrong. Every CodeRabbit agent
prompt already opens with its own directive — preserve it verbatim when delegating:

> "Verify each finding against current code. Fix only still-valid issues, skip the rest
> with a brief reason, keep changes minimal, and validate."

Hard-won failure modes to check for (real examples):
- **Wrong finding** — CodeRabbit flagged `beach.jpg` as a typo for `beech.jpg`; the CDN
  asset was genuinely `beach.jpg` (200) and `beech.jpg` 404'd. Applying it would have
  broken the image. **Verify external/factual claims (curl URLs, grep the source) before editing.**
- **Stale finding** — a comment pointed at `IntakeReview.test.tsx` after that file was
  deleted in a refactor. Skip with a reason.
- **Already fixed** — comments carry a `✅ Addressed in commit <sha>` marker once resolved.

## Workflow

### 1. Resolve the PR number
If not given, find it for the current branch:
```bash
gh pr view --json number,title,headRefName,baseRefName,state 2>/dev/null \
  || gh pr list --head "$(git branch --show-current)" --json number,title,url
```

### 2. Harvest every CodeRabbit comment
CodeRabbit posts to THREE places — pull all three:
```bash
PR=<number>; REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
# (a) Review-level bodies (summaries + collapsed nitpick lists, "Actionable comments posted: N")
gh pr view "$PR" --json reviews \
  --jq '.reviews[] | select(.author.login=="coderabbitai") | "\(.submittedAt) [\(.state)]\n\(.body)\n==="'
# (b) Inline line comments (most actionable findings live here)
gh api "repos/$REPO/pulls/$PR/comments" --paginate \
  --jq '.[] | select(.user.login=="coderabbitai[bot]") | "FILE \(.path):\(.line // .original_line) created=\(.created_at)\n\(.body)\n----------"'
# (c) Issue-level comments (walkthrough, command replies)
gh api "repos/$REPO/issues/$PR/comments" --paginate \
  --jq '.[] | select(.user.login=="coderabbitai[bot]") | .body'
```
Notes:
- The newest review's `[state]` matters: `CHANGES_REQUESTED` blocks merge; `COMMENTED` does not.
  GitHub keeps showing the last *requesting* review as the gate until CodeRabbit issues an Approve.
- An `[!CAUTION] Outside diff range comments` block holds findings on lines outside the diff —
  they are still real; don't miss them.

### 3. Triage into a worklist
For each finding, record: `file:line`, severity (Major/Minor/Nitpick, "Potential issue" vs nitpick),
the **🤖 Prompt for AI Agents** text (the block inside the `<summary>🤖 Prompt for AI Agents</summary>`
fenced code), and a status:
- `ADDRESSED` — has `✅ Addressed in commit` → skip.
- `OPEN` — actionable now.
- Prioritize Major/"Potential issue" over Nitpicks. Tell the user the worklist before fanning out.

### 4. Fan out subagents (one per still-open finding, in parallel)
Send independent findings in a SINGLE message with multiple Agent tool calls so they run
concurrently. Use the `executor` (or `general-purpose`) agent. Feed each the CodeRabbit prompt
**verbatim**, wrapped so the agent verifies first and may skip:

> Verify each finding against current code. Fix only still-valid issues, skip the rest with a
> brief reason, keep changes minimal, and validate.
>
> <paste the exact CodeRabbit "Prompt for AI Agents" block>
>
> Constraints: change only what's needed; don't touch unrelated code, config, or generated files;
> do NOT commit or push. After editing, run the affected test(s) and report FIXED (one-line change)
> or SKIPPED (reason) plus the test result.

Group trivially-related findings in the same file into one subagent to avoid edit collisions.
Never run parallel agents that edit the same file.

### 5. Validate
Run the project's test/lint/typecheck (prefer the `check` agent, asking for each relevant check, to
keep output out of the main context). Confirm green before reporting.

### 6. Report, then commit on request only
Summarize per-finding: FIXED / SKIPPED(reason) / REJECTED(evidence). Commit & push **only when the
user asks**. When committing in a Craft Digital / personal repo, obey the standing rule:
**no mention of Claude, Anthropic, or any coding agent in commit or PR messages**, and drop the
`Co-Authored-By` trailer.

### 7. Reply to CodeRabbit and drive it to Approve
When the user wants CodeRabbit's formal sign-off:
- Post a PR comment documenting any **rejected/skipped** findings with evidence, so reviewers see
  they were checked, not ignored.
- Repo config matters: `.coderabbit.yaml` with `reviews.request_changes_workflow: true` makes
  CodeRabbit post a gating "Request changes" review that only flips to **Approve** once findings
  are resolved. Branch protection blocks merge on a standing request-changes review even when
  `required_approving_review_count` is 0.
- **Incremental vs full:** `@coderabbitai review` is incremental and will NOT re-issue a verdict on
  already-reviewed commits (it replies "does not re-review already reviewed commits"). To get a
  fresh **Approve** after fixes, post **`@coderabbitai full review`** — it re-evaluates the whole PR
  in its current state. Use **`@coderabbitai resolve`** first to clear stale comment threads.
- If CodeRabbit's *status check* passes but its *review state* is still `CHANGES_REQUESTED` from an
  old review, the clean unblock is to **dismiss that stale review** in the GitHub UI (or
  `gh api -X PUT repos/$REPO/pulls/$PR/reviews/<id>/dismissals -f message=...`), which needs the
  dismiss permission.

## Handy CodeRabbit chat commands
- `@coderabbitai full review` — re-review the whole PR from scratch (use this to earn an Approve).
- `@coderabbitai review` — incremental review of new commits only.
- `@coderabbitai resolve` — mark all CodeRabbit comment threads resolved.
- `@coderabbitai pause` / `resume` — stop/start auto-reviews.

## Checking the verdict
```bash
gh pr view "$PR" --json reviewDecision,mergeStateStatus,mergeable
gh pr checks "$PR"   # CodeRabbit appears as a status check named "CodeRabbit"
```
`reviewDecision: APPROVED` + passing checks + `mergeStateStatus` not `BLOCKED` = clear to merge.
