#!/usr/bin/env bash
# PreToolUse gate: the main session may not edit files directly, so the work
# goes to a subagent. Subagent tool calls carry agent_id in the hook input;
# main-session calls don't. Escape hatch: touch ~/.claude/delegate-gate.off
# or launch with CLAUDE_DELEGATE_GATE=off (the off-file expires after 12 hours;
# see _gate-common.sh).
#
# Also usable on the Bash tool: in the main session, high-confidence file
# writes (redirects, tee, sed -i / perl -i / awk -i inplace) are denied too.
# Deliberately out of scope: cp, mv, rm, git, package managers, and
# interpreters writing files. This closes an obvious bypass; it is not a
# sandbox. Parsing lives in _bash-write-check.py and fails open.
#
# A target held in a variable is judged like the literal path when the variable
# is set by a plain literal assignment certain to have run on the same line
# (the shared walker's rule, _cmd_dirs.py), and the same goes for writes inside
# `bash -c`, `sh -c`, `eval` and `env -S` bodies (three deep). A target that
# still cannot be resolved (`f=$(mktemp); cmd > "$f"`, an environment variable,
# a loop variable) stays ALLOWED. This is deliberate: writing to a temporary
# file through a variable is an everyday pattern, and this gate does not deny
# on an unknown target. Without _cmd_dirs.py only literal targets are judged.
# Limits: a relative write target is judged as written, so `cd <allowed dir> &&
# echo hi > notes.md` is denied in the main session (also inside a body); cp,
# mv, install, dd, truncate, touch, mkdir and rm are not treated as writes (with
# a literal path or a variable); an unexported outer variable is assumed visible
# inside a single-quoted body. If the shared walker cannot be loaded, one line
# goes to standard error and only literal targets are judged.
set -uo pipefail
payload="$(cat)"

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  # Shared file unavailable: behave as gate ON.
  gate_is_off() { return 1; }
  gate_expired_note() { :; }
fi
gate_is_off && exit 0

agent_id="$(jq -r '.agent_id // empty' <<<"$payload")"
[ -n "$agent_id" ] && exit 0

deny() {
  local note; note="$(gate_expired_note)"
  jq -n --arg r "$1" --arg n "$note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ($r + (if $n != "" then " " + $n else "" end))
    }
  }'
  exit 0
}

scratch="$(jq -r '.scratchpad_dir // empty' <<<"$payload")"

# Bash calls: tool_name is "Bash" (fall back to tool_input.command being present).
tool_name="$(jq -r '.tool_name // empty' <<<"$payload")"
command_str="$(jq -r '.tool_input.command // empty' <<<"$payload")"
if [ "$tool_name" = "Bash" ] || [ -n "$command_str" ]; then
  [ -z "$command_str" ] && exit 0
  # Cheap prefilter so ordinary read-only commands skip python startup.
  printf '%s' "$command_str" | grep -qE '>|\btee\b|\b(sed|perl|awk|gawk)\b' || exit 0
  command -v python3 >/dev/null 2>&1 || exit 0
  target="$(CMD="$command_str" GATE_HOME="$HOME" GATE_SCRATCH="$scratch" \
    python3 "$_gate_dir/_bash-write-check.py")" || exit 0
  [ -z "$target" ] && exit 0
  deny "Delegation gate: the main session does not write files, including through Bash. Writes go through a subagent (Agent tool, usually executor; pick the smallest model that fits). Escape hatch: touch ~/.claude/delegate-gate.off (expires after 12 hours) or launch with CLAUDE_DELEGATE_GATE=off. Blocked write target: $target"
fi

path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$payload")"

# Config, memory, plans, and the session scratchpad stay writable.
case "$path" in
  "$HOME"/.claude/*|"$HOME"/.claude-personal/*|*/.claude/*) exit 0 ;;
esac
if [ -n "$scratch" ] && [[ "$path" == "$scratch"/* ]]; then
  exit 0
fi

deny "Delegation gate: the main session does not edit files. Hand this to a subagent (Agent tool, usually executor) and pick the smallest model that fits, per CLAUDE.md. Blocked path: $path"
