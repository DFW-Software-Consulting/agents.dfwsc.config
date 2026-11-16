#!/usr/bin/env bash
# Shared by enforce-response-cap.sh (Stop) and reply-cap-prompt.sh
# (UserPromptSubmit). Sourced, not executed. Holds the reply cap, the phrases
# that approve a long reply, and the approval marker paths.
#
# Approval markers are files named reply-cap-approval-<session> containing
# "oneshot" or "session". They live under scratchpad_dir when the payload gives
# one, else under ${XDG_CACHE_HOME:-$HOME/.cache}/claude-hooks. Writers use the
# first directory; readers and clearers check both, so a payload that carries
# scratchpad_dir on one event and not the other still finds the marker.

REPLY_CAP_CHARS=1200
# Whole phrases (case-insensitive) that approve one long reply. "expand" counts
# only when it is the entire trimmed prompt.
REPLY_CAP_ONESHOT_PHRASES="go long|no limit|full writeup|full write-up|more detail"
REPLY_CAP_SESSION_ON_PHRASE="limit off"
REPLY_CAP_SESSION_OFF_PHRASE="limit on"

# reply_cap_has_phrase LOWERCASED_TEXT PHRASE: whole-phrase match.
reply_cap_has_phrase() {
  printf '%s\n' "$1" | grep -qE "(^|[^a-z0-9])$2([^a-z0-9]|\$)"
}

# reply_cap_classify PROMPT: prints session | clear | oneshot | none.
# "limit on" wins over "limit off", which wins over the one-shot phrases.
reply_cap_classify() {
  local p t
  p="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if reply_cap_has_phrase "$p" "$REPLY_CAP_SESSION_OFF_PHRASE"; then echo clear; return; fi
  if reply_cap_has_phrase "$p" "$REPLY_CAP_SESSION_ON_PHRASE"; then echo session; return; fi
  if reply_cap_has_phrase "$p" "($REPLY_CAP_ONESHOT_PHRASES)"; then echo oneshot; return; fi
  t="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ "$t" = "expand" ]; then echo oneshot; return; fi
  echo none
}

# reply_cap_dirs SCRATCHPAD_DIR: prints candidate marker dirs, writer first.
reply_cap_dirs() {
  local s="$1" base
  [ -n "$s" ] && [ -d "$s" ] && echo "$s"
  base="${XDG_CACHE_HOME:-}"
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
