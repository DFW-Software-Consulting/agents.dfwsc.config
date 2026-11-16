#!/usr/bin/env bash
# UserPromptSubmit: records long-reply approvals and tells Claude the reply cap
# up front, so it is not first learned from the Stop hook after the reply has
# already shown. Approval phrases and marker paths live in _reply-cap-common.sh;
# enforce-response-cap.sh honours the marker. Fails open on any error.
payload="$(cat 2>/dev/null)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0
jq -e '.prompt | type == "string"' >/dev/null 2>&1 <<<"$payload" || exit 0

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_dir/_reply-cap-common.sh" 2>/dev/null; then
  # Shared file unavailable: plain cap, no approvals.
  echo "Reply length cap: keep conversational text to at most 1200 characters (fenced code blocks are not counted)."
  exit 0
fi

prompt="$(jq -r '.prompt' <<<"$payload" 2>/dev/null)" || exit 0
sid="$(jq -r '.session_id // empty | strings' <<<"$payload" 2>/dev/null)"
sdir="$(jq -r '.scratchpad_dir // empty | strings' <<<"$payload" 2>/dev/null)"

# A new prompt ends any one-shot approval left by an interrupted turn. A
# session-long approval is left alone; only "limit on" ends it.
[ "$(reply_cap_state "$sid" "$sdir")" = oneshot ] && reply_cap_clear "$sid" "$sdir"
before="$(reply_cap_state "$sid" "$sdir")"

case "$(reply_cap_classify "$prompt")" in
  oneshot) [ "$before" = session ] || reply_cap_set "$sid" "$sdir" oneshot ;;
  session) reply_cap_set "$sid" "$sdir" session ;;
  clear) reply_cap_clear "$sid" "$sdir" ;;
esac

case "$(reply_cap_state "$sid" "$sdir")" in
  oneshot) echo "Long reply approved for this turn: the ${REPLY_CAP_CHARS}-character reply cap does not apply to this reply only." ;;
  session) echo "Long replies approved for this session: the ${REPLY_CAP_CHARS}-character reply cap is off until the user says \"limit on\"." ;;
  *) echo "Reply length cap: keep conversational text to at most ${REPLY_CAP_CHARS} characters (fenced code blocks are not counted) unless the user asks for a long answer." ;;
esac
exit 0
