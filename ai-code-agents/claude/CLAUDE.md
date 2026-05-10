# Global Claude Instructions

## Git Commits
- Do NOT mention coding agents (like Claude, "Claude Code", Anthropic, etc.) in commit messages or PR messages. Write commit/PR messages as if they were written by the developer.

## Token Conservation (IMPORTANT)
- For ANY file search, codebase exploration, or "where does X live" task → delegate to the `codebase-locator` subagent
- For ANY "how does X work" analysis → delegate to the `codebase-analyzer` subagent
- For ANY code review or audit → delegate to the `antipattern-sniffer` subagent
- For ANY typecheck run → delegate to the `typecheck` subagent
- For ANY test run → delegate to the `test-runner` subagent
- Do NOT read large files or run verbose commands in the main conversation — delegate first, summarize back
- Prefer `effort: low` for straightforward tasks; only use high effort when reasoning is genuinely needed
