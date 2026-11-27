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
- Optional Gate 1 and Gate 2 approval links.
- Optional notes from the user about why the change is minimal and what was verified.
- The `git-verify` result when there is one (`result.results[]`, each with `cmd` and `exit`).

## Procedure

1. Run `~/.claude/local-hooks/git-facts.sh --dir <path>`. If `pushed` is false or `push_ahead` is above 0, return `blocked` with `blocked_by: ["unpushed"]` and `next: ["git-push"]`.
1a. Run `~/.claude/local-hooks/gh-repo.sh --dir <path>`. It prints `{"repo":"OWNER/REPO","remote":...,"branch":...}` from the branch's push remote (pushRemote, else `remote.pushDefault`, else the branch's remote, else origin), never from `gh`'s own default, which can point at another repository (a public upstream, for example). If it exits 2 (`no-remote`, `push-disabled`, `unresolvable`, `not-a-repo`), return `blocked` with `blocked_by: ["repo-unresolved"]`, the helper's `error` and `message` in `result`, and do not call `gh`. Pass the value as `--repo <OWNER/REPO>` on every `gh` call that takes that flag, but not on `gh auth status` and any `gh` command that takes no `--repo`.
2. Pick the template: `pr_template` from the facts if set, else `~/.claude/skills/git-pr/templates/pr-body.md`.
3. Read `git log --oneline <changes.base>..HEAD` and `git diff <changes.base>...HEAD`, where `changes.base` is the remote default branch ref from the facts (never a possibly stale local branch). Fill the sections: what changed (3 to 5 bullets), why it is the smallest viable change (one sentence), and verification: each command in `results` with `exit` 0 as a checked item on the template line its script name matches (build, test, lint or typecheck); a result that matches no line goes on one extra line. Template lines with no result stay unchecked with `TBD: not run`.
3a. Saved Brain task: run `~/.claude/skills/brain-task-sync/brain-task.sh <path> get`. When it prints `task=<id>`, add the plain line `Brain-Task: <id>` (no list marker, no placeholder; short_id, or the uuid if that is what is saved) as its own paragraph, with a blank line before and after, never appended to a list item: directly after the template's links or references block (the `Links to` / Gate lines) when it has one, otherwise as the last paragraph of the body. When nothing is saved, add nothing. No portal link is added: none is documented. If the helper is missing or exits non-zero, report that in one line and continue as if nothing were saved; it is never a blocker.
4. Placeholder rule: keep every heading in order, but remove a section the template marks as conditional ("only if ...") when it does not apply. No angle-bracket placeholders or HTML comments may remain. For a value you do not have, write a `TBD:` line with the reason (for example `Gate 1: TBD: no approval link given`); omit the `Links to` line when there is no issue number.
5. Size: use `changes.total` from the facts. The limit is the one the template states (the bundled template says 200 lines); a repository template that states none has no limit, so report `cap: null`. Over the limit, warn in the report and add a short split plan to the body. A warning does not stop the PR.
6. Write a title of at most 72 characters in the style of the recent commits.
7. If `codeowners` is set, read that file and list the owners that match the changed paths in `result.codeowners`. Do not request reviewers.
8. Create it: `gh pr create --repo <OWNER/REPO> --title "<title>" --body-file <tmpfile> --base <base> --head <branch>`, with the body written to a temporary file outside the repo.
9. If `gh` is missing or not logged in (`gh auth status`), return `blocked` with `blocked_by: ["gh-missing"]`, the filled `body` and the exact `command` for the user to run by hand.

Text that credits a coding agent is denied by a hook; write the body as the developer would.

## Output

```json
{"skill":"git-pr","status":"ok","branch":"<branch>","head":"<sha>","blocked_by":[],"result":{"repo":"<OWNER/REPO>","pr_url":"<url>","title":"...","base":"main","template_used":"repo|sop","loc":{"insertions":0,"deletions":0,"total":0,"cap":200},"codeowners":["..."],"brain_task":"<id|null>"},"next":[]}
```

- `repo` is the repository the PR was opened in, resolved from the push remote and passed as `--repo`.
- `brain_task` is the saved task id from the helper, or null.
- `template_used` is `repo` when the repository's own template was used, `sop` for the bundled one.
- `blocked` with `gh-missing` returns `result: {"body":"...","command":"gh pr create --repo <OWNER/REPO> ..."}`; `repo-unresolved` returns `result: {"error":"...","message":"..."}`; `unpushed` returns `result: {}` and `next: ["git-push"]`. `next` is a hint; the router decides.

## Does not

- Commit, push, run checks or edit files.
- Add reviewers, labels or assignees.
- Include secrets, tokens or machine-specific details in the body.
