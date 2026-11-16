---
name: git-push
description: Use when asked to push the current branch to its remote after it was committed and verified. Publishes the branch with upstream tracking and reports; never forces or retries around a failure.
---

# Git Push

One job: publish the current branch.

## Inputs

- The worktree path.
- The branch and the `head` sha expected to be pushed (from `git-commit` or `git-verify`).
- Optional remote name (default `origin`).

## Procedure

1. Run `~/.claude/local-hooks/git-facts.sh --dir <path>`. If the repo has no remote, `branch` is null (detached HEAD), or `head` in the facts differs from the expected sha, return `blocked` with `blocked_by` of `["no-remote"]`, `["detached-head"]` or `["head-mismatch"]`.
2. Run `git -C <path> push -u <remote> <branch>` once. A new branch gets its upstream set by `-u`; an existing one is pushed as a plain fast-forward.
3. If the push is rejected as non-fast-forward (diverged history), run `git -C <path> status -sb`, return `blocked` with `blocked_by: ["diverged"]` and the ahead/behind counts, and stop. Say that rebasing or merging is the user's call.
4. If the push fails for any other reason, including a hook denial or a remote hook, return `blocked` with the reason in `blocked_by` and the last lines of output in `result.log_tail`.
5. On success, re-run `git-facts.sh` and report `upstream`.

A force push or a push to the default branch is denied by a hook; do not try to work around it. Repository pre-push hooks run inside `git push`, so do not run them yourself.

## Output

```json
{"skill":"git-push","status":"ok","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"pushed_sha":"<sha>","remote":"origin","upstream":"origin/<branch>","new_branch":true},"next":["git-pr"]}
```

- `new_branch` is true when the branch had no upstream before the push.
- On `blocked`, `result` holds `log_tail` and, for `diverged`, `ahead` and `behind`; `next` is `[]`.

## Does not

- Commit, verify, open a PR or change any file.
- Force push, delete remote branches, push tags, or push anything but the current branch.
- Resolve diverged history or retry with different flags.
