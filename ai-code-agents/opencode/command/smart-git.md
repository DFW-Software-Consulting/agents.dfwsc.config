---
description: Safely stage all changes, commit with diff stats + truncated inline diff, and push only after branch status/rebase checks.
---

# Smart Git Commit & Push (Safe + Rebase-Aware)

Use best-practice Git flow: inspect branch health first, avoid destructive commands, rebase cleanly when needed, then continue the user's request.

If the user explicitly requests it, you may skip pre-commit hooks with `git commit -n`.

## Safety Rules (MUST follow)

- Start with branch status checks before staging, committing, or pushing.
- Never run destructive commands unless the user explicitly asks:
  - `git reset --hard`
  - `git clean -fd` / `git clean -fdx`
  - `git push --force` / `git push --force-with-lease`
  - `git checkout -- <path>`
- Prefer rebase-based synchronization over merge commits for pull/update flow.
- If rebase has conflicts, stop and report conflict files; do not auto-resolve silently.

## Context Gathering (Do this first)

- Current branch: !`git branch --show-current`
- Branch status: !`git status -sb`
- Upstream tracking branch (if any)
- Whether the branch needs rebase before push

## Implementation Steps

### Step 1: Branch Health Check
1. Get current branch.
2. Run branch status (`git status -sb`).
3. Detect upstream (`@{u}`) if it exists.
4. Fetch latest remote refs for this branch (do not fail if upstream is missing).
5. Compute ahead/behind against upstream when available.
6. Decide rebase plan:
   - If behind and working tree is clean: rebase now.
   - If behind and working tree has local edits: defer until after commit.

### Step 2: Pre-stage Diff Snapshot
1. Compute diff stats versus upstream (or origin/<branch> fallback).
2. Build a truncated unified diff (default max 200 lines) for commit body context.

### Step 3: Stage Changes
1. If there are no local changes, exit cleanly with a no-op summary.
2. Stage all requested changes (`git add -A` unless user scope says otherwise).

### Step 4: Commit with Inline Diffs
1. Build commit message with branch name, "Changes Summary:" (diff stats), "Detailed Diffs" (truncated unified diff).
2. Commit staged changes.
3. If nothing to commit after staging, exit cleanly.

### Step 5: Sync + Push (non-destructive)
1. If upstream does not exist, push with `-u`.
2. If upstream exists, push normally.
3. If push is rejected for non-fast-forward: rebase and retry.
4. If rebase conflicts occur, stop and report; do not force push.

## Success Criteria
- Branch status and rebase need checked before any write action
- No destructive Git action taken
- Rebase handled cleanly when required (or conflict surfaced clearly)
- Commit message includes stats + truncated diff
- User receives mini command explainer summary
