#!/usr/bin/env bash
# Handback gate for subagents. One script for two events, detected by
# hook_event_name:
#   PreToolUse (matcher SubagentHandback): inspects tool_input.message, denies.
#   SubagentStop: inspects last_assistant_message, blocks.
# A report must have an "Acceptance check" section with no "not met" line, and a
# "Context docs:" line. Each agent is sent back at most HANDBACK_SEND_BACK_CAP
# times; after that the report goes through as is. For every agent type, exempt
# ones included, a report longer than handback_max_chars (default 4000, env
# CLAUDE_HANDBACK_MAX_CHARS) is also sent back. Fails open on any error.
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
  HANDBACK_SEND_BACK_CAP=2
  handback_max_chars() {
    local v="${CLAUDE_HANDBACK_MAX_CHARS:-}"
    case "$v" in ''|*[!0-9]*) echo 4000; return ;; esac
    v=$((10#$v)); [ "$v" -gt 0 ] || v=4000; echo "$v"
  }
  acceptance_gate_is_off() { [ "${CLAUDE_ACCEPTANCE_GATE:-on}" = "off" ]; }
  acceptance_gate_expired_note() { :; }
  handback_is_exempt() {
    local t="$1" e; [ -n "$t" ] || return 1
    for e in $HANDBACK_EXEMPT_TYPES; do [ "$e" = "$t" ] && return 0; done; return 1
  }
fi
acceptance_gate_is_off && exit 0
off_note="$(acceptance_gate_expired_note 2>/dev/null)"

event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null)" || exit 0
agent_id="$(jq -r '.agent_id // empty' <<<"$payload" 2>/dev/null)" || exit 0
[ -n "$agent_id" ] || exit 0
agent_type="$(jq -r '.agent_type // empty' <<<"$payload" 2>/dev/null)" || exit 0
exempt=0
handback_is_exempt "$agent_type" && exempt=1

case "$event" in
  PreToolUse) field='.tool_input.message' ;;
  SubagentStop)
    [ "$(jq -r '.stop_hook_active // false' <<<"$payload" 2>/dev/null)" = "true" ] && exit 0
    field='.last_assistant_message' ;;
  *) exit 0 ;;
esac
# Missing, null or non-string text: nothing to inspect, allow, do not count.
jq -e "$field | type == \"string\"" >/dev/null 2>&1 <<<"$payload" || exit 0
text="$(jq -r "$field" <<<"$payload" 2>/dev/null)" || exit 0

# State file keyed by agent_id: holds a send-back count, or "passed".
sdir="$(jq -r '.scratchpad_dir // empty | strings' <<<"$payload" 2>/dev/null)"
if [ -z "$sdir" ] || [ ! -d "$sdir" ]; then
  base="${XDG_CACHE_HOME:-}"
  if [ -z "$base" ]; then [ -n "${HOME:-}" ] || exit 0; base="$HOME/.cache"; fi
  sdir="$base/claude-hooks"
fi
mkdir -p "$sdir" 2>/dev/null || exit 0
key="$(printf '%s' "$agent_id" | tr -c 'A-Za-z0-9_-' '_')"
state="$sdir/handback-${key:0:100}.state"
write_state() { { printf '%s' "$1" >"$state"; } 2>/dev/null; }
cur="$(cat "$state" 2>/dev/null)" || cur=""
count=0
if [ "$cur" = "passed" ]; then
  # Agent already passed. Stop: allow and clear (a resumed agent is checked afresh).
  # Hand-back: a fresh count.
  if [ "$event" = "SubagentStop" ]; then rm -f "$state" 2>/dev/null; exit 0; fi
else
  case "$cur" in ''|*[!0-9]*) ;; *) count="$cur" ;; esac
fi
# finish: let the report through. Stop clears state; hand-back records "passed".
finish() { if [ "$event" = "SubagentStop" ]; then rm -f "$state" 2>/dev/null; else write_state passed; fi; exit 0; }
[ "$count" -ge "$HANDBACK_SEND_BACK_CAP" ] && finish

problems=()
max_chars="$(handback_max_chars)"
text_len="$(jq -r "$field | length" <<<"$payload" 2>/dev/null)" || text_len=0
case "$text_len" in ''|*[!0-9]*) text_len=0 ;; esac
if [ "$text_len" -gt "$max_chars" ]; then
  problems+=("Your report is ${text_len} characters; the limit is ${max_chars} (a report of exactly ${max_chars} is fine). Shorten it by dropping detail and keeping the conclusions. If you can write files, put the detail in a file and give its path in the report.")
fi
# Parse the report. Prints NOSECTION, UNMET or OK.
verdict=SKIP
if [ "$exempt" -eq 0 ]; then verdict="$(awk '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
# Status of a criterion line: "met" or "not"; "" when none found.
function status(line,   t, n, f, i, w, nw, a, x, k) {
  t = tolower(line)
  sub(/^[ \t]*(>[ \t]*)?([-*+]|[0-9]+[.)]|✓|✔|✗|✘|✅|❌|☑|☐)?[ \t]*/, "", t)
  x = t
  gsub(/ - |—|–|\||:|\(/, "\001", x)
  n = split(x, f, "\001")
  for (i = 1; i <= n; i++) {
    k = f[i]; gsub(/\*\*|__|`/, "", k); k = trim(k); sub(/[.,;]+$/, "", k)
    if (k == "met") return "met"
    if (k == "not met" || k == "unmet" || k == "partially met") return "not"
  }
  gsub(/[^a-z0-9]+/, " ", t)
  nw = split(t, w, " ")
  for (i = 1; i <= nw; i++) {
    if (w[i] == "unmet") return "not"
    if ((w[i] == "not" || w[i] == "partially") && w[i+1] == "met") return "not"
    if (w[i] == "met") return "met"
  }
  return ""
}
{
  low = tolower($0)
  if (!on) {
    if (low ~ /^[ \t]*(>[ \t]*)?([-*+][ \t]+|[0-9]+[.)][ \t]+)?(#+[ \t]*)?(\*\*|__)?[ \t]*acceptance checks?([^a-z0-9]|$)/) { on = 1; found = 1 }
    next
  }
  if (low ~ /^[ \t]*#+[ \t]/) exit
  if (low ~ /^[ \t]*(\*\*|__)[^*_]*(\*\*|__)[ \t]*:?[ \t]*$/) exit
  if (low ~ /^[ \t]*(>[ \t]*)?([-*+][ \t]+|[0-9]+[.)][ \t]+)?(\*\*|__)?context docs(\*\*|__)?[ \t]*(:|-|–|—)/) exit
  if (trim($0) == "") next
  lines[++nl] = $0
  if ($0 ~ /^[ \t]*([-*+][ \t]|[0-9]+[.)][ \t]|\||✓|✔|✗|✘|✅|❌|☑|☐)/) crit[nl] = 1
  anycrit = anycrit || crit[nl]
}
END {
  if (!found) { print "NOSECTION"; exit }
  for (i = 1; i <= nl; i++) {
    if (anycrit && !crit[i]) continue
    if (status(lines[i]) == "not") { print "UNMET"; exit }
  }
  print "OK"
}' <<<"$text")"; fi
case "$verdict" in
  NOSECTION)
    problems+=("Your report has no 'Acceptance check' section. Check every acceptance criterion from your brief against what you actually did, run the checks, fix what fails, and add a section headed 'Acceptance check' with one line per criterion: '<criterion> : met | not met : <evidence>'.") ;;
  UNMET)
    problems+=("Your Acceptance check has criteria marked 'not met'. Fix the unmet criteria, or if you are truly blocked say what blocks it, then hand back again.") ;;
esac
if [ "$exempt" -eq 0 ] && ! grep -qiE '^[[:space:]]*(>[[:space:]]*)?([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)?(\*\*|__)?context docs(\*\*|__)?[[:space:]]*(:|-|–|—)' <<<"$text"; then
  problems+=("Your report has no 'Context docs:' line. End it with 'Context docs: updated <files>', 'Context docs: no change needed, <reason>' or 'Context docs: none in this repo' (update docs/context first if the repo has it).")
fi

if [ "${#problems[@]}" -eq 0 ]; then finish; fi

write_state "$((count + 1))" || true
reason="Handback sent back (attempt $((count + 1)) of $HANDBACK_SEND_BACK_CAP). ${problems[*]}${off_note:+ $off_note}"
if [ "$event" = "PreToolUse" ]; then
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  jq -n --arg r "$reason" '{decision:"block",reason:$r}'
fi
exit 0
