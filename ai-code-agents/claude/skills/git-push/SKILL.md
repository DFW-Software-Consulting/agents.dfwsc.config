---
name: git-push
description: Use when asked to push the current branch to its remote after it was committed and verified. Publishes the branch with upstream tracking and reports; never forces or retries around a failure.
---

# Git Push

One job: publish the current branch.

## Inputs

- The worktree path.
- The branch and the `head` sha expected to be pushed (from `git-commit` or `git-verify`).

## Procedure

1. Run `~/.claude/local-hooks/git-facts.sh --dir <path>`. If the repo has no remote, `branch` is null (detached HEAD), or `head` in the facts differs from the expected sha, return `blocked` with `blocked_by` of `["no-remote"]`, `["detached-head"]` or `["head-mismatch"]`.
2. Read `pushed`, `push_ahead` and `push_behind` from the facts. If `pushed` is true and `push_behind` is above 0, return `blocked` without pushing: `["diverged"]` when `push_ahead` is also above 0, `["behind"]` otherwise, with both counts in `result`. Say that rebasing or merging is the user's call. If `pushed` is true and both counts are 0, push nothing and return `ok` (nothing new to publish).
3. Run `git -C <path> push -u <push_remote> <branch>` once. `new_branch` is true when `pushed` was false in step 2.
4. If the push is rejected as non-fast-forward, return `blocked` with `blocked_by: ["diverged"]` and stop. If it fails for any other reason, including a hook denial or a remote hook, return `blocked` with `blocked_by: ["push-failed"]` and the last lines of output in `result.log_tail`.
5. On success, re-run `git-facts.sh` and report `push_ref` as `upstream`.

A force push or a push to the default branch is denied by a hook; do not try to work around it. Repository pre-push hooks run inside `git push`, so do not run them yourself. The remote-tracking counts come from the last fetch, so a stale count is possible; the push itself is the final test.

## Output

```json
{"skill":"git-push","status":"ok","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"pushed_sha":"<sha>","remote":"origin","upstream":"origin/<branch>","new_branch":true},"next":["git-pr"]}
```

- On `blocked`, `result` holds `log_tail` and, for `diverged` and `behind`, `ahead` and `behind`; `next` is `[]`. `next` is a hint; the router decides.

## Does not

- Commit, verify, open a PR or change any file.
- Force push, delete remote branches, push tags, or push anything but the current branch.
- Resolve diverged history or retry with different flags.
