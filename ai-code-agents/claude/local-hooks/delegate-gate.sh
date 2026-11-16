#!/usr/bin/env bash
# PreToolUse gate: the main session may not edit files directly, so the work
# goes to a subagent. Subagent tool calls carry agent_id in the hook input;
# main-session calls don't. Escape hatch: touch ~/.claude/delegate-gate.off
# or launch with CLAUDE_DELEGATE_GATE=off.
set -uo pipefail
payload="$(cat)"

[ "${CLAUDE_DELEGATE_GATE:-on}" = "off" ] && exit 0
[ -e "$HOME/.claude/delegate-gate.off" ] && exit 0

agent_id="$(jq -r '.agent_id // empty' <<<"$payload")"
[ -n "$agent_id" ] && exit 0

path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$payload")"
scratch="$(jq -r '.scratchpad_dir // empty' <<<"$payload")"

# Config, memory, plans, and the session scratchpad stay writable.
case "$path" in
  "$HOME"/.claude/*|"$HOME"/.claude-personal/*|*/.claude/*) exit 0 ;;
esac
if [ -n "$scratch" ] && [[ "$path" == "$scratch"/* ]]; then
  exit 0
fi

jq -n --arg p "$path" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Delegation gate: the main session does not edit files. Hand this to a subagent (Agent tool, usually executor) and pick the smallest model that fits, per CLAUDE.md. Blocked path: " + $p)
  }
}'
