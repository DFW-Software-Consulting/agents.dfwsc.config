#!/usr/bin/env bash
# PreToolUse gate on Agent: a main-session subagent call (non-exempt type) must
# carry an acceptance section in its prompt. Fails open on any error.
# Off switch: CLAUDE_ACCEPTANCE_GATE=off, or a fresh (under 12 hours old)
# ~/.claude/acceptance-gate.off, path overridable with
# CLAUDE_ACCEPTANCE_GATE_OFF_FILE (see _handback-common.sh).
set -uo pipefail
payload="$(cat 2>/dev/null)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_dir/_handback-common.sh" 2>/dev/null; then
  HANDBACK_EXEMPT_TYPES="Explore codebase-locator codebase-analyzer context-synthesis check web-fetch claude-code-guide Plan statusline-setup antipattern-sniffer fork"
  acceptance_gate_is_off() { [ "${CLAUDE_ACCEPTANCE_GATE:-on}" = "off" ]; }
  acceptance_gate_expired_note() { :; }
  handback_is_exempt() {
    local t="$1" e; [ -n "$t" ] || return 1
    for e in $HANDBACK_EXEMPT_TYPES; do [ "$e" = "$t" ] && return 0; done; return 1
  }
fi
acceptance_gate_is_off && exit 0
off_note="$(acceptance_gate_expired_note 2>/dev/null)"

[ -z "$(jq -r '.agent_id // empty' <<<"$payload" 2>/dev/null)" ] || exit 0
sub="$(jq -r '.tool_input.subagent_type // empty | strings' <<<"$payload" 2>/dev/null)" || exit 0
handback_is_exempt "$sub" && exit 0
jq -e '.tool_input | type == "object" and (.prompt | type == "string")' >/dev/null 2>&1 <<<"$payload" || exit 0
prompt="$(jq -r '.tool_input.prompt // empty | strings' <<<"$payload" 2>/dev/null)" || exit 0

if grep -qiE '^[[:space:]]*([-*+]|[0-9]+[.)])?[[:space:]]*(#+[[:space:]]*|\*\*)?[[:space:]]*(acceptance criteria|success criteria|done when|definition of done|done means)' <<<"$prompt"; then
  exit 0
fi

jq -n --arg n "$off_note" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Add a \"Done when\" section to the subagent prompt listing checkable criteria (one per line, each something the subagent can verify and report on). The subagent must report against them." + (if $n != "" then " " + $n else "" end))
  }
}'
exit 0
