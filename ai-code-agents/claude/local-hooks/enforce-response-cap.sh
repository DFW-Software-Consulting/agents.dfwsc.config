#!/bin/bash
# Stop hook: nags Claude when its last conversational reply exceeded the
# 1200-char cap defined in ~/.claude/CLAUDE.md ("Response length (default cap)").
#
# LIMITATION (by design of Claude Code's hook model): there is no hook that
# can see or edit the assistant's text before it is displayed. This hook only
# runs *after* the turn has already been shown to the user. So it cannot
# truncate/hide an overlong reply that already rendered — it can only detect
# the violation and force one corrective follow-up turn.
#
# Code/diff/tool-output content is excluded from the count by stripping
# fenced ``` code blocks before measuring length, per the cap's own rule.

input=$(cat)

# Avoid infinite loops: stop_hook_active is true when Claude Code is already
# continuing because a previous Stop hook blocked this same turn.
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$active" = "true" ]; then
  exit 0
fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
  exit 0
fi

len=$(jq -s -r '
  ([.[] | select(.type=="assistant")] | last // {})
  | (.message.content // [])
  | map(select(.type=="text") | .text) | join("\n")
  | gsub("```.*?```"; ""; "sg")
  | length
' "$transcript" 2>/dev/null)

if [ -z "$len" ] || ! [ "$len" -eq "$len" ] 2>/dev/null; then
  exit 0
fi

if [ "$len" -gt 1200 ]; then
  reason="Your last reply's conversational text ran ${len} characters, over the 1200-character cap in ~/.claude/CLAUDE.md (code/diffs/tool output are excluded from the count). That reply already displayed and can't be un-shown, but send a short follow-up acknowledging it and keep future replies under the cap unless the user has approved more."
  jq -n --arg reason "$reason" '{"decision":"block","reason":$reason}'
fi
exit 0
