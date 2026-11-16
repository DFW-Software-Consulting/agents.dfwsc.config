---
name: git
description: Git commit, push, PR, and issue workflows via the git-workflow procedure (/git commit|push|pr|issue ...). Runs hooks, never bypasses failures.
---

# Git Workflow Delegate

> **Arguments:** the text typed after `/git` reaches you as the user instruction alongside the skill invocation. Wherever this skill says "the request" (called `$ARGUMENTS` in the original Claude command), it means that text.

> **Delegation:** use Hermes' `delegate_task` tool (`tasks=[{goal, context}, ...]`; a subagent sees only its own `goal` and `context`, so make both self-contained). If `delegate_task` is unavailable, do the work directly in this session.

Handle the user's request (the request) with the git workflow procedure in `references/git-workflow.md` (this skill's directory is printed as `[Skill directory: ...]` in the skill message; the file is at `<skill dir>/references/git-workflow.md`).

Run the git operations in isolated context via `delegate_task` (one task) so git status, diffs, hooks, and CLI output stay out of the main conversation. In the task `goal`, state the user's request and tell the subagent to follow the procedure in that file; give it the absolute path of the file in `context`. The subagent must pause for the user's approval of commit groups/messages (the procedure requires it): have it return the proposal to you, relay it to the user, and continue only after approval.

Supported forms:

- `/git commit ...` — inspect changes, propose commit grouping and messages, ask for approval, then commit only approved groups.
- `/git push ...` — run the pre-push safety gate and push lifecycle.
- `/git pr ...` — run the full push + PR lifecycle using project templates and `gh pr create`.
- `/git issue ...` — create a GitHub issue from project templates or the SOP issue template.

For `/git pr`, always use the PR workflow in the reference. Do not use a separate git command flow.

Prerequisite: `gh` CLI installed and authenticated (the procedure falls back to printing the filled template if not).
