---
allowed-tools: Bash(git:*), Bash(gh:*)
description: Run git commit, push, PR, and issue workflows through git-workflow.
---

# Git Workflow

Use `git-workflow` for the user's request: `$ARGUMENTS`. If the `git-workflow` skill is not installed for this tool, follow the workflow rules in this command directly.

Supported forms:
- `/git commit ...` — inspect changes, propose commit grouping and messages, ask for approval, then commit only approved groups.
- `/git push ...` — run pre-push checks and push.
- `/git pr ...` — run the PR lifecycle using project templates and `gh pr create`.
- `/git issue ...` — create a GitHub issue using project templates or SOP defaults.

For commits, do not stage anything until the user approves the exact file group and commit message. Never use destructive git commands, `--no-verify`, force push, or direct pushes to `main`/`master` unless explicitly allowed by the workflow.
