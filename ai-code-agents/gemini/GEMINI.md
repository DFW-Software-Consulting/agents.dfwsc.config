# Global Gemini Instructions

## Git Commits
- Do NOT mention coding agents (like Gemini, Google, Claude, etc.) in commit messages or PR messages. Write commit/PR messages as if they were written by the developer.

## Execution Defaults
- Make small, scoped changes that match the surrounding codebase.
- Use the narrowest verification that proves the change, and report skipped checks.
- Do not overwrite unrelated user changes in a dirty worktree.
- Use local agents or shared skills when they match the task; Gemini has no orchestrator in this setup.
