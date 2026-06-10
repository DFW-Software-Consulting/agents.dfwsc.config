# Global Claude Instructions

Normal sessions behave normally: you may read, write, and edit files, and run
commands directly. For small or trivial changes, just do the work yourself.

## Delegation

- For large, cross-cutting, or multi-part tasks, prefer delegating discrete
  units of work to specialized subagents via the Task tool.
- An `orchestrator` agent is available when you want pure delegation and
  coordination — reasoning and dispatching to other agents without doing the
  implementation directly. Invoke it explicitly for that mode; it carries the
  full orchestration workflow and agent-routing table.

## Git Commits
- Do NOT mention coding agents (like Claude, "Claude Code", Anthropic, etc.) in commit messages or PR messages.

## Token Conservation
- Do NOT read large files or run verbose commands in the main conversation. Delegate when context will be large, noisy, or cross-cutting.
- Prefer `effort: low` for straightforward subagent tasks.
