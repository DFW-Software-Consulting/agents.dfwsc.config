#!/usr/bin/env bash
# SessionStart hook, matcher "startup|clear". NOT registered by this repo.
#
# Prints ONE line pointing at the newest hand-off note written for the
# session's folder, so a cold start can find it. Nothing from a note's content
# is ever printed: only the configured directory, the validated file name and
# an age computed from the file's modification time.
#
# Config (local file, parsed as data, never sourced):
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/handoff-pointer.conf
#   HANDOFF_DIR=<absolute path, only [A-Za-z0-9/._~-], leading ~ = home>
#   MAX_AGE_HOURS=<1..720, default 48; anything else falls back to 48>
# See handoff-pointer.conf.example.
#
# Silent (exit 0, no stderr) unless: event is SessionStart, source is startup
# or clear, agent_type is absent or empty, cwd is absolute, and a candidate
# note matches. Candidates: regular files (not links) directly in HANDOFF_DIR
# named YYYY-MM-DD_HH-MM-SS_<name>.md, young enough. Newest name first, at most
# 5 headers (first 5 lines, 4096 bytes) are read; a note matches when a path
# token in the header equals the session root (git top level, else cwd) or,
# only inside a git repository, lies below it. Paths from a note are never
# used for git, cd or anything but string comparison.
#
# Safe registration order: merge and update the live checkout first; create the
# conf; pipe a sample payload to the live script; only then add, identically in
# every settings file, a SessionStart group with matcher "startup|clear", the
# command `bash <path to this hook> 2>/dev/null || true` and a 5 second
# timeout; then start one session in a repository and one in the home
# directory.
#
# When the home directory is itself a git repository, a session below it counts
# as inside that repository, so notes naming folders under it match.
# A note naming a path with "/.." never matches. git and header reads run under
# `timeout` when it exists (2 s and 1 s); a timeout means silence.
#
# Requires: bash 4+, jq, find. Fails open on any error.
set -uo pipefail
exec 2>/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export LC_ALL=C

command -v jq >/dev/null || exit 0
payload="$(head -c 1048576)" || exit 0
jq -e 'type == "object"' >/dev/null <<<"$payload" || exit 0

field() { jq -r --arg k "$1" 'if (.[$k] | type) == "string" then .[$k] else "" end' <<<"$payload"; }
event="$(field hook_event_name)" || exit 0
source_="$(field source)" || exit 0
cwd="$(field cwd)" || exit 0
agent="$(jq -r 'if has("agent_type") and .agent_type != null and .agent_type != "" then "x" else "" end' <<<"$payload")" || exit 0
[ "$event" = SessionStart ] || exit 0
case "$source_" in startup|clear) ;; *) exit 0 ;; esac
[ -z "$agent" ] || exit 0
case "$cwd" in /*) ;; *) exit 0 ;; esac
case "$cwd" in *$'\n'*) exit 0 ;; esac
while [ "${#cwd}" -gt 1 ] && [ "${cwd%/}" != "$cwd" ]; do cwd="${cwd%/}"; done

home="${HOME:-}"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || [ -n "$home" ] || exit 0
conf="${CLAUDE_CONFIG_DIR:-$home/.claude}/handoff-pointer.conf"
[ -f "$conf" ] && [ -r "$conf" ] || exit 0
dir=""; max=48
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in
    HANDOFF_DIR=*) dir="${line#HANDOFF_DIR=}" ;;
    MAX_AGE_HOURS=*)
      v="${line#MAX_AGE_HOURS=}"
      if [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$v))" -ge 1 ] && [ "$((10#$v))" -le 720 ]; then max="$((10#$v))"; else max=48; fi ;;
  esac
done < "$conf"
[[ "$dir" =~ ^[A-Za-z0-9/._~-]+$ ]] || exit 0
tilde="~"
if [ "$dir" = "$tilde" ] || [ "${dir:0:2}" = "$tilde/" ]; then
  [ -n "$home" ] || exit 0
  dir="$home${dir:1}"
  [[ "$dir" =~ ^[A-Za-z0-9/._~-]+$ ]] || exit 0   # HOME is not trusted: check the expanded value too
fi
case "$dir" in /*) ;; *) exit 0 ;; esac
while [ "${#dir}" -gt 1 ] && [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done
[ -d "$dir" ] || exit 0

to() { # to SECONDS CMD...: run under timeout when available
  if command -v timeout >/dev/null; then timeout "$@"; else shift; "$@"; fi
}

# Session root: git top level when cwd is inside a repository, else cwd.
sroot="$cwd"; in_repo=0
top="$(to 2 git -C "$cwd" rev-parse --show-toplevel)"; grc=$?
[ "$grc" -ne 124 ] || exit 0
if [ "$grc" -eq 0 ] && [ -n "$top" ] && [[ "$top" == /* ]] && [[ "$top" != *$'\n'* ]]; then
  sroot="$top"; in_repo=1
fi

name_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_[A-Za-z0-9._-]{1,80}\.md$'
valid_name() { [[ "$1" =~ $name_re ]] && [[ "$1" != *..* ]]; }

now="$(date +%s)" || exit 0
limit=$((max * 3600))
declare -A mtime=()
names=()
while IFS= read -r -d '' rec; do
  t="${rec%% *}"; n="${rec#* }"; t="${t%.*}"
  [[ "$t" =~ ^[0-9]+$ ]] || continue
  valid_name "$n" || continue
  age=$((now - t))
  [ "$age" -ge 0 ] && [ "$age" -le "$limit" ] || continue
  mtime["$n"]="$t"; names+=("$n")
done < <(find -H "$dir" -maxdepth 1 -type f -name '*.md' -printf '%T@ %f\0')
[ "${#names[@]}" -gt 0 ] || exit 0
mapfile -t sorted < <(printf '%s\n' "${names[@]}" | sort -r)

matches() { # $1 = path token
  local tok="$1"
  [[ "$tok" != *"/.."* ]] || return 1
  while [[ "$tok" == *[./] ]]; do tok="${tok%?}"; done
  [ -n "$tok" ] || return 1
  [ "$tok" = "$sroot" ] && return 0
  [ "$in_repo" = 1 ] && [[ "$tok" == "$sroot"/* ]] && return 0
  return 1
}

checked=0
for name in "${sorted[@]}"; do
  [ "$checked" -lt 5 ] || exit 0
  checked=$((checked + 1))
  f="$dir/$name"
  raw="$(to 1 head -c 4096 -- "$f" | head -n 5; printf x)" || continue
  raw="${raw%x}"
  size="$(to 1 head -c 4096 -- "$f" | head -n 5 | wc -c)" || continue
  [ "${#raw}" -eq "$size" ] || continue   # a NUL byte was dropped: binary, skip
  mapfile -t lines <<<"$raw"
  # cut by the byte limit: a token touching the end of the buffer may be a prefix
  cut=0; [ "$size" -ge 4096 ] && [ "${raw: -1}" != $'\n' ] && cut=1
  lastidx=$((${#lines[@]} - 1))
  found=0
  for i in 1 0 2 3 4; do
    [ -n "${lines[$i]:-}" ] || continue
    while IFS= read -r tok; do
      if [ "$cut" = 1 ] && [ "$i" = "$lastidx" ] && [[ "${lines[$i]}" == *"$tok" ]]; then continue; fi
      if matches "$tok"; then found=1; break; fi
    done < <(grep -o -E '/[A-Za-z0-9/._~+-]+' <<<"${lines[$i]}")
    [ "$found" = 1 ] && break
  done
  if [ "$found" = 1 ]; then
    hours=$(( (now - mtime[$name]) / 3600 ))
    msg="Handoff note from ${hours}h ago for this folder: $dir/$name. Read it only if the user says to continue."
    jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}' || true
    exit 0
  fi
done
exit 0
