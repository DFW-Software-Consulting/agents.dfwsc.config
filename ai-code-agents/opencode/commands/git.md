---
agent: git-runner
description: Delegate git commit, push, PR, and issue workflows to a git subagent using the git-workflow skill.
---

# Git Workflow Delegate

Use the `git-workflow` skill for the user's request: `$ARGUMENTS`.

Launch the `git-runner` subagent to handle the git workflow in isolated context. Model assignment comes from the active OpenCode config.

## Supported Requests

- `/git commit ...` — inspect current changes, propose logical commit grouping, propose commit messages, ask for user approval, then commit only approved groups.
- `/git push ...` — run the git-workflow push lifecycle, including required pre-push checks.
- `/git pr ...` — run the git-workflow PR lifecycle, including template detection and `gh pr create`.
- `/git issue ...` — run the git-workflow issue lifecycle, including template detection and `gh issue create`.

## Subagent Prompt

```text
You are executing the git-workflow skill for this user request:

$ARGUMENTS

Use the repository's git-workflow rules as the source of truth.
Use the configured `git-runner` subagent and the repository's git-workflow rules.

For commit requests:
- Inspect the current branch and working tree before staging anything.
- Inspect changed files and diffs.
- Group files into logical commits when more than one coherent change is present.
- Propose the commit grouping and exact commit message before committing.
- Ask the user to approve or revise the grouping/message.
- Iterate until the user approves.
- Stage only the approved files for each approved commit group.
- Never commit unreviewed or unrelated files.
- Never push unless the user explicitly requested push or PR.

For push requests:
- Run the git-workflow push lifecycle.
- Never force push or rewrite history.
- Stop and report if hooks or checks fail.

For PR requests:
- Run the git-workflow PR lifecycle.
- Use `gh pr create` when available and authenticated.
- Read and fill the project's PR template when present.
- If `gh` is unavailable, return the filled PR body and exact command for manual use.

For issue requests:
- Run the git-workflow issue lifecycle.
- Use `gh issue create` when available and authenticated.
- Read and fill the project's issue template when present.
- Ask for missing acceptance criteria or verification details before creating vague issues.

Safety rules:
- Do not use destructive git commands.
- Do not use `--no-verify`.
- Do not push directly to main/master.
- Do not mention coding agents in commit messages, PR bodies, or issue bodies.

Return a concise summary of what happened, including any commit hashes, PR URL, issue URL, blocked checks, or required next steps.
```
