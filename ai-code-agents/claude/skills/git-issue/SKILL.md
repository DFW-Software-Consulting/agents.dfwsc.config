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
2. Pick the template from `issue_templates` in the facts: match the request's type (bug, feature, task) against each `.md` template's file name or front matter. If a Markdown template and a `.yml` form share a name, use the Markdown one. Forms cannot be filled through `--body`, so with no clear match, or only forms, use `~/.claude/skills/git-issue/templates/issue-body.md`. Never just take the first one.
3. Fill the sections from the description. Do not invent facts: for anything the user did not give, write what is known and add it to `open_questions`.
4. Placeholder rule (same as git-pr): keep every heading in order, but remove a section the template marks as conditional ("only if ...") when it does not apply, such as the split plan. No angle-bracket placeholders or HTML comments may remain; write a `TBD:` line with the reason instead.
5. If there are no acceptance criteria, do not stop to ask. Put this line under that section and carry on: `TBD: acceptance criteria not provided (open question)`.
6. Size: pick one box from the description. If the size is unknown, leave the boxes unchecked and add it to `open_questions`. Above 200 lines, fill the split plan section.
7. Create it: `gh issue create --title "<title>" --body-file <tmpfile>`, with the body written to a temporary file outside the repo.
8. If `gh` is missing or not logged in (`gh auth status`), return `blocked` with `blocked_by: ["gh-missing"]`, the filled `body` and the exact `command` for the user to run by hand.

Write the issue as the developer would, with no credit to any coding tool.

## Output

```json
{"skill":"git-issue","status":"ok","branch":"<branch or null>","head":"<sha or null>","blocked_by":[],"result":{"issue_url":"<url>","number":0,"template_used":"repo|sop","open_questions":["..."]},"next":[]}
```

- `blocked` with `gh-missing` returns `result: {"body":"...","command":"gh issue create ...","open_questions":[...]}`. `next` is a hint; the router decides.
- The issue number can be passed to `git-pr` later as `Links to: #N`.

## Does not

- Commit, push, open a PR or edit files.
- Assign, label or milestone the issue.
- Include secrets, tokens or machine-specific details.
