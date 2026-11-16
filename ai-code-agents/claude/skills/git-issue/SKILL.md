---
name: git-issue
description: Use when asked to create a GitHub issue. Fills the repository's issue template (or the bundled one) from the user's description and runs gh issue create. Never blocks to ask; missing acceptance criteria are marked TBD.
---

# Git Issue

One job: create a GitHub issue from a template.

## Inputs

- The repository path.
- A title or description of the work, plus anything the user said about acceptance criteria, size and files.

## Procedure

1. Run `~/.claude/local-hooks/git-facts.sh --dir <path>`.
2. Pick the template: the first `.md` file in `issue_templates` from the facts. A `.yml` issue form cannot be filled through `--body`, so if only forms exist, use `~/.claude/skills/git-issue/templates/issue-body.md`. Keep every heading exactly as written and leave no placeholder text behind.
3. Fill the sections from the description. Do not invent facts: for anything the user did not give, write what is known and add it to `open_questions`.
4. If there are no acceptance criteria, do not stop to ask. Put this line under that section and carry on: `TBD: acceptance criteria not provided (open question)`.
5. Pick one size box from the description. If it is above 200 lines, fill the split plan section; otherwise remove that section.
6. Create it: `gh issue create --title "<title>" --body-file <tmpfile>`, with the body written to a temporary file outside the repo.
7. If `gh` is missing or not logged in (`gh auth status`), return `blocked` with `blocked_by: ["gh-missing"]`, the filled `body` and the exact `command` for the user to run by hand.

Text that credits a coding agent is denied by a hook; write the issue as the developer would.

## Output

```json
{"skill":"git-issue","status":"ok","branch":"<branch or null>","head":"<sha or null>","blocked_by":[],"result":{"issue_url":"<url>","number":0,"template_used":"repo|sop","open_questions":["..."]},"next":[]}
```

- `blocked` with `gh-missing` returns `result: {"body":"...","command":"gh issue create ...","open_questions":[...]}`.
- The issue number can be passed to `git-pr` later as `Links to: #N`.

## Does not

- Commit, push, open a PR or edit files.
- Assign, label or milestone the issue.
- Include secrets, tokens or machine-specific details.
