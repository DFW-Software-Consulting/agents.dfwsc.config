# Global Codex Instructions

## Git Commits

- Do not mention coding agents, Codex, OpenAI, Claude, OpenCode, or other AI tools in commit messages or PR messages. Write commit and PR messages as if they were written by the developer.

## Context Discipline

- Use `rg` and `rg --files` first for text and file search.
- Keep noisy exploration, long logs, and broad audits out of the main thread when a focused subagent can do the work.
- For broad "where does this live" searches, spawn the `codebase-locator` subagent.
- For cross-module "how does this work" analysis, spawn the `codebase-analyzer` subagent.
- For code review or audit work that is more than a small local diff, spawn the `antipattern-sniffer` or `code-reviewer` subagent.
- For lint, typecheck, prettier, and test runs, use the corresponding custom subagent when available so the main thread receives a concise report.

## Execution Defaults

- Prefer small, scoped edits that match the existing codebase.
- Run the narrowest verification command that proves the change; broaden verification when the risk or blast radius is larger.
- If a command needs network access, writes outside the workspace, or a privileged action, explain why and request approval.
- Do not revert unrelated user changes in a dirty worktree.

## Skills

- Use skills when the task matches a skill description.
- Prefer checked-in skills from `.agents/skills` for repository-specific workflows and user-level skills from `~/.agents/skills` for shared workflows.
- For route/domain audits, use the `route-audit` skill.
