#!/usr/bin/env bash
# PreToolUse gate on Agent/Task: every subagent call must pass an explicit
# `model` so the orchestrator picks one per call. Forks ignore model, so they
# are exempt. Fails open (allow) if jq is missing or the input can't be parsed.
# Escape hatch: same as delegate-gate.sh (see _gate-common.sh: off-file expires
# after 12h, or CLAUDE_DELEGATE_GATE=off).
set -uo pipefail
payload="$(cat)"

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  # Shared file unavailable: behave as gate ON.
  gate_is_off() { return 1; }
  gate_expired_note() { :; }
fi
gate_is_off && exit 0
command -v jq >/dev/null 2>&1 || exit 0

jq -e . >/dev/null 2>&1 <<<"$payload" || exit 0

subagent="$(jq -r '.tool_input.subagent_type // empty' <<<"$payload" 2>/dev/null)" || exit 0
[ "$subagent" = "fork" ] && exit 0

model="$(jq -r '.tool_input.model // empty | strings' <<<"$payload" 2>/dev/null)" || exit 0
[ -n "$model" ] && exit 0

note="$(gate_expired_note)"
jq -n --arg note "$note" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "Set `model` on every Agent call (haiku | sonnet | opus): pick the smallest model that will get it right. Each agent'"'"'s description lists a suggested model; override it when the task warrants." + (if $note != "" then " " + $note else "" end)
  }
}'
exit 0
