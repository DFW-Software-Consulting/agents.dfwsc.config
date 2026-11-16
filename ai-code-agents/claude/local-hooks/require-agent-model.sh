#!/usr/bin/env bash
# PreToolUse gate on Agent/Task: every subagent call must pass an explicit
# `model` so the orchestrator picks one per call. Forks ignore model, so they
# are exempt. Fails open (allow) if jq is missing or the input can't be parsed.
# Escape hatch: touch ~/.claude/delegate-gate.off (same as delegate-gate.sh).
set -uo pipefail
payload="$(cat)"

[ -e "$HOME/.claude/delegate-gate.off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

jq -e . >/dev/null 2>&1 <<<"$payload" || exit 0

subagent="$(jq -r '.tool_input.subagent_type // empty' <<<"$payload" 2>/dev/null)" || exit 0
[ "$subagent" = "fork" ] && exit 0

model="$(jq -r '.tool_input.model // empty | strings' <<<"$payload" 2>/dev/null)" || exit 0
[ -n "$model" ] && exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "Set `model` on every Agent call (haiku | sonnet | opus): pick the smallest model that will get it right. Each agent'"'"'s description lists a suggested model; override it when the task warrants."
  }
}'
exit 0
