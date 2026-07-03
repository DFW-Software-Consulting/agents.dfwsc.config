# Global Claude Instructions

Normal sessions behave normally: you may read, write, and edit files, and run
commands directly. But by default, hand real implementation work to the
`executor` subagent rather than doing it inline — see Delegation.

## Delegation

- **Default execution to the `executor` subagent (Sonnet).** Any concrete,
  already-decided implementation work — multi-step edits, changes spanning more
  than one file, running builds/scripts, mechanical refactors — goes to
  `executor` via the Task tool, not the main model. This keeps routine execution
  on the cheaper model and reserves the main model for reasoning, review, and
  coordination. When in doubt on something non-trivial, delegate.
- **Do it yourself only when delegating would cost more than it saves:** a single
  trivial edit (a one-line fix, a rename, a config toggle), or work so tightly
  coupled to the live conversation that re-specifying it to a subagent would lose
  context the executor needs. The overhead of spawning a subagent is real — don't
  pay it for a two-line change.
- For large, cross-cutting, or multi-part tasks, delegate discrete units to the
  right specialized subagents (not just `executor`); the orchestrator's routing
  table maps task types to agents.
- An `orchestrator` agent is available when you want pure delegation and
  coordination — reasoning and dispatching to other agents without doing the
  implementation directly. Invoke it explicitly for that mode; it carries the
  full orchestration workflow and agent-routing table.

## Git Commits
- Do NOT mention coding agents (like Claude, "Claude Code", Anthropic, etc.) in commit messages or PR messages.

## Token Conservation
- Do NOT read large files or run verbose commands in the main conversation. Delegate when context will be large, noisy, or cross-cutting.
- Prefer `effort: low` for straightforward subagent tasks.
