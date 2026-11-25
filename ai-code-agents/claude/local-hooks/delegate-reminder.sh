#!/usr/bin/env bash
# UserPromptSubmit: one-line reminder of the delegation rule on every turn.
cat >/dev/null
_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  # Shared file unavailable: behave as gate ON.
  gate_is_off() { return 1; }
  gate_expired_note() { :; }
fi
gate_is_off && exit 0
echo "Delegation mode: do the work through subagents (Agent tool) and set the model per call: haiku for lookups, search, mechanical edits, running checks; sonnet for multi-file implementation and debugging; opus only for architecture or genuinely hard reasoning. Ask each subagent for a short report. Never poll CI with sleep loops or a waiting subagent; the one script the main thread may run itself is pr-wait (if it is on PATH), in Bash with run_in_background and no file redirects, then dispatch the next agent when it exits. The main thread plans, coordinates, reviews, and talks to JC."
gate_expired_note
