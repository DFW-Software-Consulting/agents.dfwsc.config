#!/usr/bin/env bash
# UserPromptSubmit: one-line reminder of the delegation rule on every turn.
cat >/dev/null
[ -e "$HOME/.claude/delegate-gate.off" ] && exit 0
echo "Delegation mode: do the work through subagents (Agent tool) and set the model per call: haiku for lookups, search, mechanical edits, running checks; sonnet for multi-file implementation and debugging; opus only for architecture or genuinely hard reasoning. Ask each subagent for a short report. The main thread plans, coordinates, reviews, and talks to JC."
