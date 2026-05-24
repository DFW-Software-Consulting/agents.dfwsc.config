# Global Claude Instructions

## Git Commits
- Do NOT mention coding agents (like Claude, "Claude Code", Anthropic, etc.) in commit messages or PR messages. Write commit/PR messages as if they were written by the developer.

## Token Conservation (IMPORTANT)
- For file search, codebase exploration, or "where does X live" tasks:
  - Handle directly in the main agent when scope is small/simple (for example: <= 3 files, <= 2 search patterns, or a quick known-path lookup)
  - Delegate to the `codebase-locator` subagent for broad, ambiguous, or multi-area searches
- For "how does X work" analysis:
  - Handle directly in the main agent when scope is small/simple (for example: a single function, file, or short local flow)
  - Delegate to the `codebase-analyzer` subagent for cross-module, architectural, or deep behavior analysis
- For code review or audit:
  - Handle directly in the main agent for small diffs or narrow checks
  - Delegate to the `antipattern-sniffer` subagent for comprehensive or high-risk reviews
- For ANY typecheck run → delegate to the `typecheck` subagent
- For ANY lint run → delegate to the `lint` subagent
- For ANY test run → delegate to the `test-runner` subagent
- Do NOT read large files or run verbose commands in the main conversation. Delegate when context will be large, noisy, or cross-cutting.
- Prefer `effort: low` for straightforward tasks; only use high effort when reasoning is genuinely needed
