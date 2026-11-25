---
name: git-workflow
description: Stub. The git workflow is now five single-purpose skills (git-commit, git-verify, git-push, git-pr, git-issue) plus the advisory brain-task-sync; delegate through the git-workflow agent or /git, which sequences them.
---

# Git Workflow (moved)

This workflow is now five skills, each with one job and a fixed result envelope:

- `git-commit`: group changes, propose messages, commit what was approved.
- `git-verify`: run the project's checks for the current commit and record the result.
- `git-push`: publish the current branch.
- `git-pr`: open a pull request from a pushed branch.
- `git-issue`: create an issue from a template.
- `brain-task-sync`: after a push or PR, note progress on the user's own Brain task (advisory; never blocks the chain).

The `git-workflow` agent (or `/git`) picks the chain for a request and passes each result to the next skill. Load the individual skill you need, not this stub.
