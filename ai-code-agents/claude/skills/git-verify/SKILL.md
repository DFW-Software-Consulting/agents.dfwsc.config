---
name: git-verify
description: Use when asked to verify that the current commit passes the project's checks (typecheck, lint, test) and record the result before pushing. Runs run-checks.sh once and reports; never fixes anything.
---

# Git Verify

One job: prove the current commit passes the project's checks and record the stamp.

## Inputs

- The worktree path.
- Optional `build: true` to include the build script.

## Procedure

1. Run `~/.claude/local-hooks/run-checks.sh --dir <path>` (add `--build` when asked) exactly once. Read the JSON it prints.
2. Do not edit code, do not fix failures, do not retry, do not commit.
3. Get the branch with `git -C <path> branch --show-current`.

The script refuses to run on a dirty tree (tracked files only) because checks must describe the commit, not uncommitted edits.

## Output

Return exactly this envelope and nothing else of substance:

```json
{"skill":"git-verify","status":"ok","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"head":"<sha>","stamp":"<path>","status":"passed","results":[{"cmd":"...","exit":0,"tail":"..."}]},"next":["git-push"]}
```

- `status` is `ok` when the script reports `passed` or `none_detected`. `next` is `["git-push"]`.
- `status` is `blocked` when it reports `failed`: `blocked_by` lists the failing commands and `next` is `[]`.
- `status` is `blocked` when it reports `dirty` or `dirty_after`: `blocked_by` is `["dirty-tree"]`, `next` is `[]`, and say to commit, gitignore or remove the listed paths and run again.
- `status` is `blocked` when it reports `error` (exit 2): `blocked_by` is `["error"]`, `next` is `[]`, and include the script's message.

## Notes

- The stamp is tied to the commit. Any new commit or amend needs a new run.
- Untracked files that are not gitignored count as dirty, before and after the run.
- A repo opts into explicit checks with a `.claude/git-checks` file (one shell command per line, `#` comments allowed). Without it, checks come from `package.json` scripts. A file whose only non-comment line is `none` opts the repo out.
- The commands in that file or in `package.json` run as-is from the repository. Only use this skill on repositories the user trusts.
