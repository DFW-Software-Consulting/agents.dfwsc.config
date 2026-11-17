#!/bin/bash
# Stop hook: nags Claude when its last conversational reply exceeded the
# reply cap (1200 chars, see _reply-cap-common.sh and ~/.claude/CLAUDE.md
# "Response length (default cap)").
#
# LIMITATION (by design of Claude Code's hook model): there is no hook that
# can see or edit the assistant's text before it is displayed. This hook only
# runs *after* the turn has already been shown to the user. So it cannot
# truncate/hide an overlong reply that already rendered — it can only detect
# the violation and force one corrective follow-up turn. reply-cap-prompt.sh
# (UserPromptSubmit) states the cap up front to reduce that.
#
# Code/diff/tool-output content is excluded from the count by stripping
# fenced ``` code blocks before measuring length, per the cap's own rule.
#
# Headless runs are exempt: a session whose entrypoint is exactly "sdk-cli" or
# "sdk-ts" (claude -p and the SDKs) has no reader to apologise to, and the
# forced apology turn would become the job's output. The entrypoint is read from
# CLAUDE_CODE_ENTRYPOINT in the hook's environment, else from the transcript:
# every "entrypoint" value in it must be the same allowed one, so a session that
# began headless and was resumed interactively (mixed values) keeps the cap. An
# allow-list, never "anything but cli": cli, claude-desktop, claude-vscode, a
# missing, unknown, mixed or unreadable value all keep the cap.
#
# Long-reply approvals (written by reply-cap-prompt.sh) are honoured: a one-shot
# approval allows this reply and is removed (also when the reply was short); a
# session-long approval allows and stays until "limit on".

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$input" || exit 0

# Avoid infinite loops: stop_hook_active is true when Claude Code is already
# continuing because a previous Stop hook blocked this same turn.
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$active" = "true" ]; then
  exit 0
fi

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_dir/_reply-cap-common.sh" 2>/dev/null; then
  # Shared file unavailable: original behaviour, cap 1200, no approvals.
  REPLY_CAP_CHARS=1200
  reply_cap_state() { echo none; }
  reply_cap_clear() { :; }
fi

entrypoint="${CLAUDE_CODE_ENTRYPOINT:-}"
if [ -z "$entrypoint" ]; then
  _tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
  if [ -n "$_tp" ] && [ -f "$_tp" ]; then
    # Every distinct value; more than one (or none) is ambiguous: keep the cap.
    _eps=$(grep -oE '"entrypoint"[[:space:]]*:[[:space:]]*"[^"]*"' "$_tp" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' | sort -u)
    [ "$(printf '%s\n' "$_eps" | grep -c .)" -eq 1 ] && entrypoint="$_eps"
  fi
fi
case "$entrypoint" in
  sdk-cli|sdk-ts) exit 0 ;;
esac

sid=$(printf '%s' "$input" | jq -r '.session_id // empty | strings' 2>/dev/null)
sdir=$(printf '%s' "$input" | jq -r '.scratchpad_dir // empty | strings' 2>/dev/null)
approval="$(reply_cap_state "$sid" "$sdir")"
[ "$approval" = "oneshot" ] && reply_cap_clear "$sid" "$sdir"
[ "$approval" != "none" ] && exit 0

strip='gsub("```.*?```"; ""; "gp") | length'
len=""
if printf '%s' "$input" | jq -e '.last_assistant_message | type == "string"' >/dev/null 2>&1; then
  len=$(printf '%s' "$input" | jq -r ".last_assistant_message | $strip" 2>/dev/null)
else
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    exit 0
  fi
  # Only the last 400000 bytes of the transcript; when cut, drop the first (partial) line. Skip
  # lines that do not parse.
  drop=0
  [ "$(stat -c %s "$transcript" 2>/dev/null || echo 0)" -gt 400000 ] && drop=1
  len=$(tail -c 400000 "$transcript" 2>/dev/null | tail -n +$((drop + 1)) | jq -n -R -r "
    [inputs | try fromjson catch empty | select(type==\"object\" and .type==\"assistant\")]
    | last // {}
    | (.message.content // [])
    | if type == \"array\" then . else [] end
    | map(select(type==\"object\" and .type==\"text\") | .text) | join(\"\\n\")
    | $strip
  " 2>/dev/null)
fi

if [ -z "$len" ] || ! [ "$len" -eq "$len" ] 2>/dev/null; then
  exit 0
fi

if [ "$len" -gt "$REPLY_CAP_CHARS" ]; then
  reason="Your last reply's conversational text ran ${len} characters, over the ${REPLY_CAP_CHARS}-character cap in ~/.claude/CLAUDE.md (code/diffs/tool output are excluded from the count). That reply already displayed and can't be un-shown, but send a short follow-up acknowledging it and keep future replies under the cap unless the user has approved more."
  jq -n --arg reason "$reason" '{"decision":"block","reason":$reason}'
fi
exit 0
