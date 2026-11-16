#!/usr/bin/env bash
# Handback gate for subagents. One script for two events, detected by
# hook_event_name:
#   PreToolUse (matcher SubagentHandback): inspects tool_input.message, denies.
#   SubagentStop: inspects last_assistant_message, blocks.
# A report must have an "Acceptance check" section with no "not met" line, and a
# "Context docs:" line. Each agent is sent back at most HANDBACK_SEND_BACK_CAP
# times; after that the report goes through as is. Fails open on any error.
set -uo pipefail
payload="$(cat 2>/dev/null)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_dir/_handback-common.sh" 2>/dev/null; then
  HANDBACK_EXEMPT_TYPES="Explore codebase-locator codebase-analyzer context-synthesis check web-fetch claude-code-guide Plan statusline-setup antipattern-sniffer fork"
  HANDBACK_SEND_BACK_CAP=2
  acceptance_gate_is_off() { [ "${CLAUDE_ACCEPTANCE_GATE:-on}" = "off" ]; }
  handback_is_exempt() {
    local t="$1" e; [ -n "$t" ] || return 1
    for e in $HANDBACK_EXEMPT_TYPES; do [ "$e" = "$t" ] && return 0; done; return 1
  }
fi
acceptance_gate_is_off && exit 0

event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null)" || exit 0
agent_id="$(jq -r '.agent_id // empty' <<<"$payload" 2>/dev/null)" || exit 0
[ -n "$agent_id" ] || exit 0
agent_type="$(jq -r '.agent_type // empty' <<<"$payload" 2>/dev/null)" || exit 0
handback_is_exempt "$agent_type" && exit 0

case "$event" in
  PreToolUse) text="$(jq -r '.tool_input.message // empty | strings' <<<"$payload" 2>/dev/null)" || exit 0 ;;
  SubagentStop)
    [ "$(jq -r '.stop_hook_active // false' <<<"$payload" 2>/dev/null)" = "true" ] && exit 0
    text="$(jq -r '.last_assistant_message // empty | strings' <<<"$payload" 2>/dev/null)" || exit 0 ;;
  *) exit 0 ;;
esac

# State file keyed by agent_id: holds a send-back count, or "passed".
sdir="$(jq -r '.scratchpad_dir // empty' <<<"$payload" 2>/dev/null)"
if [ -z "$sdir" ] || [ ! -d "$sdir" ]; then sdir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-hooks"; fi
mkdir -p "$sdir" 2>/dev/null || exit 0
key="$(printf '%s' "$agent_id" | tr -c 'A-Za-z0-9_-' '_')"
state="$sdir/handback-$key.state"
cur="$(cat "$state" 2>/dev/null)" || cur=""
if [ "$cur" = "passed" ]; then [ "$event" = "SubagentStop" ] && exit 0; fi
case "$cur" in ''|*[!0-9]*) count=0 ;; *) count="$cur" ;; esac
[ "$count" -ge "$HANDBACK_SEND_BACK_CAP" ] && exit 0

problems=()
hdr='^[[:space:]]*(#+[[:space:]]*|\*\*)?[[:space:]]*acceptance check'
if ! grep -qiE "$hdr" <<<"$text"; then
  problems+=("Your report has no 'Acceptance check' section. Check every acceptance criterion from your brief against what you actually did, run the checks, fix what fails, and add a section headed 'Acceptance check' with one line per criterion: '<criterion> : met | not met : <evidence>'.")
else
  # Section runs from its header to the next markdown heading or a Context docs line.
  section="$(HDR="$hdr" awk '
    !on && tolower($0) ~ ENVIRON["HDR"] {on=1; next}
    on && /^[[:space:]]*#+[[:space:]]/ {exit}
    on && tolower($0) ~ /^[[:space:]]*(\*\*)?context docs:/ {exit}
    on {print}' <<<"$text")"
  unmet="$(grep -iE 'not met' <<<"$section" | grep -viE 'met[[:space:]]*\|[[:space:]]*not met' || true)"
  if [ -n "$unmet" ]; then
    problems+=("Your Acceptance check has criteria marked 'not met'. Fix the unmet criteria, or if you are truly blocked say what blocks it, then hand back again.")
  fi
fi
if ! grep -qiE '^[[:space:]]*(\*\*)?context docs:' <<<"$text"; then
  problems+=("Your report has no 'Context docs:' line. End it with 'Context docs: updated <files>', 'Context docs: no change needed, <reason>' or 'Context docs: none in this repo' (update docs/context first if the repo has it).")
fi

if [ "${#problems[@]}" -eq 0 ]; then
  printf 'passed' >"$state" 2>/dev/null
  exit 0
fi

printf '%s' "$((count + 1))" >"$state" 2>/dev/null || exit 0
reason="Handback sent back (attempt $((count + 1)) of $HANDBACK_SEND_BACK_CAP). ${problems[*]}"
if [ "$event" = "PreToolUse" ]; then
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  jq -n --arg r "$reason" '{decision:"block",reason:$r}'
fi
exit 0
