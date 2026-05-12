---
allowed-tools: Task(subagent:general), Bash(git:status), Bash(git:branch), Bash(git:fetch)
description: Delegate git operations to a subagent using MiniMax M2.5 free model to save context.
---

# Smart Git - Context-Free Delegate

Launch a subagent to handle git operations using the MiniMax M2.5 free model, freeing your main context.

## Delegation

Use the Task tool to launch a `general` subagent with:

**prompt:**
```
You are executing smart-git workflow for the user.

## Safety Rules (MUST follow)
- Start with branch status checks before staging, committing, or pushing.
- Never run destructive commands unless the user explicitly asks:
  - `git reset --hard`
  - `git clean -fd` / `git clean -fdx`
  - `git push --force` / `git push --force-with-lease`
  - `git checkout -- <path>`
- Prefer rebase-based synchronization over merge commits.
- If rebase has conflicts, stop and report conflict files; do not auto-resolve silently.

## Context Gathering (Do this first)

- Current branch name
- Full branch status (`ahead/behind`, staged, unstaged, untracked)
- Upstream tracking branch (if any)
- Whether the branch needs rebase before push

## Implementation Steps

### Step 1: Branch Health Check

1. Enable strict shell behavior.
2. Get current branch (`git branch --show-current`).
3. Run branch status (`git status -sb`).
4. Detect upstream (`@{u}`) if it exists.
5. Fetch latest remote refs for this branch.
6. Compute ahead/behind against upstream when available.
7. Decide rebase plan:
   - If behind and working tree is clean: rebase now.
   - If behind and working tree has local edits: note rebase is required and defer until after commit.

### Step 2: Pre-stage Diff Snapshot

1. Compute diff stats versus upstream (or origin/<branch> fallback when possible).
2. Build a truncated unified diff (default max 200 lines) for commit body context.

### Step 3: Stage Changes

1. If there are no local changes, exit cleanly with a no-op summary.
2. Stage all requested changes (`git add -A` unless user scope says otherwise).

### Step 4: Commit with Inline Diffs

1. Build commit message with:
   - Branch name
   - "Changes Summary:" section (diff stats)
   - "Detailed Diffs" section (truncated unified diff)
2. Commit staged changes.
3. If nothing to commit after staging, exit cleanly.

### Step 5: Sync + Push (non-destructive)

1. If upstream does not exist, push with `-u`.
2. If upstream exists, push normally.
3. If push is rejected for non-fast-forward:
   - Run a clean rebase onto upstream (`git pull --rebase` or equivalent branch-specific rebase).
   - Retry push.
4. If rebase conflicts occur, stop and report; do not force push.

## Validation

- Last commit message includes:
  - `Changes Summary:`
  - `Detailed Diffs`
- Branch is synchronized with upstream or a clear conflict/error reason is reported.

## Final Response Format

Provide a short learning-oriented mini summary with:

1. What you did (status check, rebase check/action, stage, commit, push).
2. Exact key commands you ran.
3. For each key command, one-line explanation of what it does.

## Success Criteria

- ✓ Branch status and rebase need checked before any write action
- ✓ No destructive Git action taken
- ✓ Rebase handled cleanly when required (or conflict surfaced clearly)
- ✓ Commit message includes stats + truncated diff
- ✓ User receives mini command explainer summary
```

**subagent_type:** general

**description:** Smart Git Operations

## Execution

1. Launch the subagent with the prompt above.
2. Wait for completion.
3. Report the subagent's summary to the user.