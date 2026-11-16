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
2. Read `git -C <path> status --short --untracked-files=all` (files are listed individually; a plain short status shows an untracked directory as one line) and the diff of each changed file. If nothing changed, return `ok` with an empty `committed` list and `next: []`.
3. Leave out, and list in `skipped` with the reason, any `.env` file (not `.env.example`, `.env.sample`, `.env.template`), private key or certificate file (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`, `id_ed25519*`) and credentials file. If a file you would commit contains conflict markers (`grep -lE '^(<<<<<<<|>>>>>>>) ' <files>`), return `blocked` with `blocked_by: ["conflict-markers"]` and the files in `result`. A hook will also check this once it is registered; do not rely on that.
4. Group the rest by coherent purpose, not by file type. Keep unrelated docs, config and code changes in separate commits. Honor the scope hint; a file you are unsure about is left out and listed under `unstaged`.
5. Write one message per group. Match the repo: if `commitlint` is true, or the last ten subjects in `git log --oneline` follow `type(scope): description`, use that form (imperative, lowercase, no period, at most 72 characters); otherwise match the recent subjects.
6. Without `approved`: commit nothing. Return `needs_input` with the proposed groups (see Output).
7. With `approved`: for each approved group in order, run `git -C <path> add -- <its files>` then `git -C <path> commit -m "<its message>" -- <its files>`. The path list on the commit keeps files that were already staged for other reasons out of it. Never `git add -A`, `git add .` or `commit -a`. Afterwards list any other staged paths (`git diff --cached --name-only`) in `left_staged`; do not unstage them.
8. Let git run the repository's own hooks on the commit; do not run husky, lint-staged or linters by hand.
9. If a commit fails, stop. Return `blocked` with `blocked_by` naming the cause (`hook-failed`, or `message-rejected` when the commit-message hook refused the text) and the last lines of output in `result.log_tail`. For `message-rejected`, add a corrected `proposed_subject`. Do not fix the cause, retry on your own or commit later groups.

Hooks you will meet: a commit in a primary checkout is denied by a hook, and so is text that credits a coding agent. Do not try to work around either; report the denial.

## Output

First call (no `approved`):

```json
{"skill":"git-commit","status":"needs_input","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"proposed":[{"subject":"...","body":"...","files":["..."]}],"unstaged":["..."],"skipped":[{"path":"...","reason":"..."}],"left_staged":["..."]},"next":["git-commit"]}
```

`next` is a hint (the router decides); here it means: call again with `approved` set to the groups the user accepted, edited if they asked for changes.

After committing:

```json
{"skill":"git-commit","status":"ok","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"committed":[{"sha":"<sha>","subject":"...","files":["..."]}],"unstaged":["..."],"skipped":[{"path":"...","reason":"..."}],"left_staged":["..."]},"next":["git-verify"]}
```

- `head` is the sha of the last commit made. `next` is `["git-verify"]` when something was committed.
- On failure: `status` is `blocked`, `blocked_by` as in step 9, `result` is `{"committed":[...so far],"log_tail":"..."}`, `next` is `[]`.

## Does not

- Push, open a PR, or run the project's checks (that is `git-verify`).
- Edit, reformat or auto-fix any source file, including to satisfy a failing hook.
- Amend, rebase or rewrite earlier commits.
