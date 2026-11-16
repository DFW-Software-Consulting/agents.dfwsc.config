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
- `status` is `blocked` when it reports `dirty`: `blocked_by` is `["dirty-tree"]`, `next` is `[]`, and say to commit first.

## Notes

- The stamp is tied to the commit. Any new commit or amend needs a new run.
- A repo opts into explicit checks with a `.claude/git-checks` file (one shell command per line, `#` comments allowed). Without it, checks come from `package.json` scripts.
