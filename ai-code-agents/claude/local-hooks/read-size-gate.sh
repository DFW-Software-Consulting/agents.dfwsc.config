#!/usr/bin/env bash
# PreToolUse gate (matcher: Read). The main session coordinates and does not
# read large text files; those reads go to a subagent. Subagent calls carry
# agent_id in the hook input and are never gated. Honours the same escape
# hatches as delegate-gate.sh (see _gate-common.sh).
# Fails open: empty/non-JSON input, a missing tool or any error means allow.
set -uo pipefail

# Defaults; override with CLAUDE_READ_GATE_MAX_LINES / CLAUDE_READ_GATE_MAX_BYTES.
DEFAULT_MAX_LINES=300
DEFAULT_MAX_BYTES=30000

payload="$(cat 2>/dev/null)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  gate_is_off() { return 1; }   # shared file unavailable: gate ON
fi
gate_is_off && exit 0

pos_int() { [[ "$1" =~ ^[1-9][0-9]{0,15}$ ]]; }
max_lines="$DEFAULT_MAX_LINES"; max_bytes="$DEFAULT_MAX_BYTES"
pos_int "${CLAUDE_READ_GATE_MAX_LINES:-}" && max_lines="$CLAUDE_READ_GATE_MAX_LINES"
pos_int "${CLAUDE_READ_GATE_MAX_BYTES:-}" && max_bytes="$CLAUDE_READ_GATE_MAX_BYTES"

{
  IFS= read -r -d '' agent_id
  IFS= read -r -d '' path
  IFS= read -r -d '' cwd
  IFS= read -r -d '' scratch
  IFS= read -r -d '' limit
  IFS= read -r -d '' pages
} < <(jq -j '[(.agent_id // ""), (.tool_input.file_path // ""), (.cwd // ""),
  (.scratchpad_dir // ""), (.tool_input.limit // "" | tostring),
  (.tool_input.pages // "" | tostring)] | map(gsub("\u0000"; "")) | .[] + "\u0000"' <<<"$payload" 2>/dev/null) || true

[ -n "$agent_id" ] && exit 0
[ -n "$path" ] || exit 0
[ -n "$pages" ] && exit 0

# Same allowlist as delegate-gate.sh: config, memory, plans, scratchpad.
case "$path" in
  "$HOME"/.claude/*|"$HOME"/.claude-personal/*|*/.claude/*) exit 0 ;;
esac
if [ -n "$scratch" ] && [[ "$path" == "$scratch"/* ]]; then exit 0; fi

# Relative paths resolve against the payload cwd.
if [[ "$path" != /* ]]; then
  [ -n "$cwd" ] || exit 0
  path="$cwd/$path"
fi
[ -f "$path" ] || exit 0

# Non-text by extension (images, PDFs, notebooks), then by NUL byte in the head.
shopt -s nocasematch
case "$path" in
  *.pdf|*.ipynb|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.ico|*.tif|*.tiff|*.svg) exit 0 ;;
esac
shopt -u nocasematch
head_len="$(head -c 8192 -- "$path" 2>/dev/null | wc -c)" || exit 0
head_nonnul="$(head -c 8192 -- "$path" 2>/dev/null | tr -d '\000' | wc -c)" || exit 0
[ "$head_len" -eq "$head_nonnul" ] || exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
ways="Delegate the read to a subagent (Agent tool) and ask for a summary, or pass offset and limit to read a known range of at most $max_lines lines."

# A limit is only honoured when numeric; non-numeric is treated as absent.
if pos_int "$limit"; then
  [ "$limit" -le "$max_lines" ] && exit 0
  deny "Read gate: limit $limit exceeds the $max_lines-line cap for reads in the main session. $ways Blocked path: $path"
fi

size="$(stat -c %s -- "$path" 2>/dev/null)" || exit 0
pos_int "$size" || exit 0
if [ "$size" -gt "$max_bytes" ]; then
  deny "Read gate: $path is $size bytes (over the $max_bytes-byte threshold) and the main session does not read large files. $ways"
fi
# Under the byte threshold, so counting lines is cheap. grep -c '' also counts an unterminated last line.
lines="$(grep -c '' -- "$path" 2>/dev/null)" || exit 0
if [ "$lines" -gt "$max_lines" ]; then
  deny "Read gate: $path is $lines lines (over the $max_lines-line threshold) and the main session does not read large files. $ways"
fi
exit 0
