---
name: git-pr
description: Use when asked to open a pull request for a branch that is already pushed. Fills the repository's PR template (or the bundled one) from the diff and runs gh pr create. Does not commit, push or verify.
---

# Git PR

One job: open a pull request from a pushed branch.

## Inputs

- The worktree path and the branch.
- Base branch (default: `default_branch` from the facts).
- Optional issue number, written as `Links to: #N`.
- Optional notes from the user about why the change is minimal and what was verified.

## Procedure

1. Run `~/.claude/local-hooks/git-facts.sh --dir <path>`. If `upstream` is null or `ahead` is above 0, the branch is not fully pushed: return `blocked` with `blocked_by: ["unpushed"]` and `next: ["git-push"]`.
2. Pick the template: `pr_template` from the facts if set, else `~/.claude/skills/git-pr/templates/pr-body.md`. Keep every heading of the template exactly as written, in order, and leave no placeholder text behind.
3. Read `git log --oneline <base>..HEAD` and the diff against the base. Fill the sections from them: what changed (3 to 5 bullets), why it is the smallest viable change (one sentence), and the verification commands that actually ran (from the `git-verify` envelope when you have one, otherwise say nothing was run).
4. Size: use `changes.total` from the facts. If it is above the cap, warn in the report and add a short split plan to the body; the template states the cap (default 200 lines, lockfiles excluded). A warning does not stop the PR.
5. Write a title of at most 72 characters in the style of the recent commits.
6. If `codeowners` is set, read that file and list the owners that match the changed paths in `result.codeowners`. Do not request reviewers.
7. Create it: `gh pr create --title "<title>" --body-file <tmpfile> --base <base> --head <branch>`, with the body written to a temporary file outside the repo.
8. If `gh` is missing or not logged in (`gh auth status`), return `blocked` with `blocked_by: ["gh-missing"]`, the filled `body` and the exact `command` for the user to run by hand.

Text that credits a coding agent is denied by a hook; write the body as the developer would.

## Output

```json
{"skill":"git-pr","status":"ok","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"pr_url":"<url>","title":"...","base":"main","template_used":"repo|sop","loc":{"insertions":0,"deletions":0,"total":0,"cap":200},"codeowners":["..."]},"next":[]}
```

- `template_used` is `repo` when the repository's own template was used, `sop` for the bundled one.
- `blocked` with `gh-missing` returns `result: {"body":"...","command":"gh pr create ..."}`; `unpushed` returns `result: {}` and `next: ["git-push"]`.

## Does not

- Commit, push, run checks or edit files.
- Add reviewers, labels or assignees.
- Include secrets, tokens or machine-specific details in the body.
