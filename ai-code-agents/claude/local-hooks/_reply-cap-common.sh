#!/usr/bin/env bash
# Shared by enforce-response-cap.sh (Stop) and reply-cap-prompt.sh
# (UserPromptSubmit). Sourced, not executed. Holds the reply cap, the phrases
# that approve a long reply, and the approval marker paths.
#
# Approval markers are files named reply-cap-approval-<session> containing
# "oneshot" or "session", always under ${XDG_CACHE_HOME:-$HOME/.cache}/claude-hooks
# (scratchpad_dir is deliberately not used: it may not be in every payload).

REPLY_CAP_CHARS=1200
# Phrases that approve one long reply (case-insensitive, whole phrase, never
# inside a fenced code block). A one-shot phrase counts when the prompt is just
# the phrase; or ends with it (after whitespace/punctuation); or starts with it
# followed directly by . , : ; ! ? or a dash with a space, or a line break; or
# it is alone on the first or last line. Trailing punctuation, "please" and
# "thanks" are ignored. "expand", "limit off" and "limit on" count only as the
# whole prompt (trailing punctuation ignored).
REPLY_CAP_ONESHOT_PHRASES="go long|no limit|full writeup|full write-up|more detail"
# Second group, "ask for more" requests: each phrase is itself a request for a
# longer answer, so the START rule is looser than for the group above: the
# phrase may be followed by a space and more words ("elaborate on the gate"),
# as long as the next character is not a letter, digit or hyphen. Whole prompt,
# end of prompt and alone on the first or last line work as for the group above.
# A phrase in the middle of a sentence never counts.
REPLY_CAP_ASKMORE_PHRASES="explain this more|explain that more|explain more|tell me more|elaborate"
REPLY_CAP_SESSION_ON_PHRASE="limit off"
REPLY_CAP_SESSION_OFF_PHRASE="limit on"

# reply_cap_strip_tail: stdin to stdout, drops trailing punctuation/space and a
# trailing "please"/"thanks" (then punctuation again).
reply_cap_strip_tail() {
  sed -E -e 's/[[:space:][:punct:]]+$//' -e 's/(^|[^a-z0-9])(please|thanks)$//' -e 's/[[:space:][:punct:]]+$//'
}

# reply_cap_classify PROMPT: prints session | clear | oneshot | none.
reply_cap_classify() {
  local t whole first last line
  # Lowercase, drop fenced code blocks, trim.
  t="$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | awk '/^[[:space:]]*```/ { f = !f; next } !f')"
  whole="$(printf '%s' "$t" | sed -E 's/^[[:space:]]+//' | sed -E 's/[[:space:][:punct:]]+$//')"
  case "$whole" in
    "$REPLY_CAP_SESSION_OFF_PHRASE") echo clear; return ;;
    "$REPLY_CAP_SESSION_ON_PHRASE") echo session; return ;;
    expand) echo oneshot; return ;;
  esac
  first="$(printf '%s\n' "$t" | sed -E '/^[[:space:]]*$/d' | head -n 1 | sed -E 's/^[[:space:]]+//')"
  if printf '%s\n' "$first" | grep -qE "^($REPLY_CAP_ONESHOT_PHRASES)( ?(-|–|—) |[.,:;!?]|\$)"; then echo oneshot; return; fi
  last="$(printf '%s\n' "$t" | sed -E '/^[[:space:]]*$/d' | tail -n 1 | reply_cap_strip_tail)"
  if printf '%s\n' "$last" | grep -qE "(^|[^a-z0-9])($REPLY_CAP_ONESHOT_PHRASES)\$"; then echo oneshot; return; fi
  # Alone on the first or last line.
  for line in "$first" "$last"; do
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//' | reply_cap_strip_tail)"
    case "$line" in
      "go long"|"no limit"|"full writeup"|"full write-up"|"more detail") echo oneshot; return ;;
    esac
  done
  # Second group: looser start rule (see REPLY_CAP_ASKMORE_PHRASES).
  if printf '%s\n' "$first" | grep -qE "^($REPLY_CAP_ASKMORE_PHRASES)([^a-z0-9-]|\$)"; then echo oneshot; return; fi
  if printf '%s\n' "$last" | grep -qE "(^|[^a-z0-9])($REPLY_CAP_ASKMORE_PHRASES)\$"; then echo oneshot; return; fi
  echo none
}

# reply_cap_dirs [ignored]: prints the one marker dir. The location does not
# depend on payload fields, so every event finds the same marker.
reply_cap_dirs() {
  local base="${XDG_CACHE_HOME:-}"
  if [ -z "$base" ]; then [ -n "${HOME:-}" ] || return 0; base="$HOME/.cache"; fi
  echo "$base/claude-hooks"
}

# reply_cap_key SESSION_ID: sanitised file-name key; empty when no session id.
reply_cap_key() {
  local k
  [ -n "$1" ] || return 0
  k="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')"
  printf '%s' "${k:0:100}"
}

# reply_cap_state SESSION_ID SCRATCHPAD_DIR: prints oneshot | session | none.
reply_cap_state() {
  local key d v
  key="$(reply_cap_key "$1")"
  [ -n "$key" ] || { echo none; return; }
  while IFS= read -r d; do
    [ -f "$d/reply-cap-approval-$key" ] || continue
    v="$(cat "$d/reply-cap-approval-$key" 2>/dev/null)"
    case "$v" in oneshot|session) echo "$v"; return ;; esac
  done < <(reply_cap_dirs "$2")
  echo none
}

# reply_cap_clear SESSION_ID SCRATCHPAD_DIR: removes the marker everywhere.
reply_cap_clear() {
  local key d
  key="$(reply_cap_key "$1")"
  [ -n "$key" ] || return 0
  while IFS= read -r d; do rm -f "$d/reply-cap-approval-$key" 2>/dev/null; done < <(reply_cap_dirs "$2")
  return 0
}

# reply_cap_set SESSION_ID SCRATCHPAD_DIR KIND: replaces the marker (writer dir).
reply_cap_set() {
  local key d
  key="$(reply_cap_key "$1")"
  [ -n "$key" ] || return 0
  reply_cap_clear "$1" "$2"
  d="$(reply_cap_dirs "$2" | head -n 1)"
  [ -n "$d" ] || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  { printf '%s' "$3" >"$d/reply-cap-approval-$key"; } 2>/dev/null
  return 0
}
