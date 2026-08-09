# Global Claude Instructions

Normal sessions behave normally: you may read, write, and edit files, and run
commands directly. But by default, hand real implementation work to the
`executor` subagent rather than doing it inline — see Delegation.

## Delegation

- **Default execution to the `executor` subagent.** Any concrete,
  already-decided implementation work — multi-step edits, changes spanning more
  than one file, running builds/scripts, mechanical refactors — goes to
  `executor` via the Task tool, not the main model. This keeps routine execution
  isolated and reserves the main session for reasoning, review, and coordination.
  When in doubt on something non-trivial, delegate.
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

## Craft Digital daily standup policy (mandatory, effective 2026-08-06)
- Every workday, all Craft Digital employees (including me, JC) must update the
  portal (portal.craftdigital.dev):
  - **By 9:30 a.m. local:** enter the day's priorities and tasks, with a time
    estimate per task, thorough and clear enough to be understood without extra
    context.
  - **At 5:30 p.m. or later local:** update with what was completed, what wasn't,
    and any blockers/delays plus what needs to happen next.
- Announced by Clinton Ehrlich in Slack #team-craftdigital on 2026-08-05.
- If a Craft Digital work session starts before the morning entry or runs past
  end of day, remind me if the corresponding portal update may still be owed.
- Portal/planner features in craft-digital-brain should be designed to serve this
  exact cadence (morning priorities + time estimates, end-of-day completion +
  blockers).

## Craft Digital Brain
- The Brain (Supabase `brain` schema, project ref `fieozyvfuhyhtuprjnwz`) is shared
  across the whole Craft Digital team, not private to me. Never update, delete,
  reassign, or "simplify" an existing Brain row (task, decision, fact, action item)
  that's owned/attributed to someone else — check `owner_person_id`, `decided_by`,
  or the equivalent attribution column before writing to any row I didn't create,
  and surface it to me instead of touching it. Applies to cleanup/consolidation
  passes too, not just new writes. See the `brain-locate` skill for the full rule.
