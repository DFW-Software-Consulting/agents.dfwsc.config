---
name: git-commit
description: Use when asked to commit working-tree changes. Groups the changes, proposes the commit messages for approval, and once approved commits exactly those groups. Does not push, run checks or edit files.
---

# Git Commit

One job: turn the working-tree changes into approved commits.

## Inputs

- The worktree path (all commands run there, never in the primary checkout).
- An optional scope hint from the user ("only the docs changes").
- `approved`: absent on the first call; on the second call, the exact groups and messages the user approved.

## Procedure

1. Run `~/.claude/local-hooks/git-facts.sh --dir <path>`. If `detached` is true or `branch` is null, return `blocked` with `blocked_by: ["detached-head"]`.
2. Read `git -C <path> status --short` and the diff of each changed file. If nothing changed, return `ok` with an empty `committed` list and `next: []`.
3. Group files by coherent purpose, not by file type. Keep unrelated docs, config and code changes in separate commits. Honor the scope hint; a file you are unsure about is left out and listed under `unstaged`.
4. Write one message per group. Match the repo: if `commitlint` is true, or the last ten subjects in `git log --oneline` follow `type(scope): description`, use that form (imperative, lowercase, no period, at most 72 characters); otherwise match the recent subjects.
5. Without `approved`: commit nothing. Return `needs_input` with the proposed groups (see Output).
6. With `approved`: for each approved group in order, run `git -C <path> add -- <its files>` then `git -C <path> commit -m "<its message>"` (or `-F` for a body). Stage only the approved files; never `git add -A`, `git add .` or `commit -a`. Anything not in an approved group stays out.
7. Run the commit once and let git run the repository's own hooks; do not run husky, lint-staged or linters by hand.
8. If a commit fails, stop. Return `blocked` with `blocked_by` naming the hook or tool that failed and the last lines of its output in `result.log_tail`. Do not fix the cause, retry with other flags or commit later groups.

Hooks you will meet: a commit in a primary checkout is denied by a hook, and so is text that credits a coding agent. Do not try to work around either; report the denial.

## Output

First call (no `approved`):

```json
{"skill":"git-commit","status":"needs_input","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"proposed":[{"subject":"...","body":"...","files":["..."]}],"unstaged":["..."]},"next":["git-commit"]}
```

`next` means: call again with `approved` set to the groups the user accepted, edited if they asked for changes.

After committing:

```json
{"skill":"git-commit","status":"ok","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"committed":[{"sha":"<sha>","subject":"...","files":["..."]}],"unstaged":["..."]},"next":["git-verify"]}
```

- `head` is the sha of the last commit made. `next` is `["git-verify"]` when something was committed.
- On failure: `status` is `blocked`, `blocked_by` as in step 8, `result` is `{"committed":[...so far],"log_tail":"..."}`, `next` is `[]`.

## Does not

- Push, open a PR, or run the project's checks (that is `git-verify`).
- Edit, reformat or auto-fix any source file, including to satisfy a failing hook.
- Amend, rebase or rewrite earlier commits.
