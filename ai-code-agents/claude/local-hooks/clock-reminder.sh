#!/usr/bin/env bash
# SessionStart / UserPromptSubmit hook: config-driven reminders by local clock
# time, shown once per calendar day per reminder name.
#
# Config: ${CLAUDE_CLOCK_REMINDERS_CONF:-$HOME/.claude/clock-reminders.conf}
# Parsed as data, never sourced. One reminder per line, '|' separated:
#   name|days|HH:MM-HH:MM|cwd_glob|message
# days: ISO weekdays (1 = Monday), list or range, e.g. 1-5 or 1,3,5.
# Window: local 24h, start inclusive, end exclusive, not crossing midnight.
# cwd_glob: shell glob matched against the payload cwd ('*' = any).
# Blank lines, '#' lines and malformed lines are ignored.
#
# Clock: `date +%Y-%m-%d %H:%M` (POSIX); the weekday is computed in bash, so
# no GNU date flags are needed. Tests set CLOCK_REMINDER_NOW="YYYY-MM-DD HH:MM".
# Requires: bash 4+, jq. Fails open: any error means no output, exit 0.
set -uo pipefail
payload="$(cat 2>/dev/null)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

conf="${CLAUDE_CLOCK_REMINDERS_CONF:-$HOME/.claude/clock-reminders.conf}"
[ -f "$conf" ] && [ -r "$conf" ] || exit 0

event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null)" || exit 0
case "$event" in SessionStart|UserPromptSubmit) ;; *) exit 0 ;; esac
cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)" || exit 0

now="${CLOCK_REMINDER_NOW:-$(date '+%Y-%m-%d %H:%M' 2>/dev/null)}"
[[ "$now" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})\ ([0-9]{2}):([0-9]{2})$ ]] || exit 0
y=$((10#${BASH_REMATCH[1]})); mo=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
nowmin=$((10#${BASH_REMATCH[4]} * 60 + 10#${BASH_REMATCH[5]}))
today="${now%% *}"
[ "$mo" -ge 1 ] && [ "$mo" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] || exit 0

# ISO weekday (1 = Monday) via Sakamoto's method.
t=(0 3 2 5 0 3 5 1 4 6 2 4)
yy=$y; [ "$mo" -lt 3 ] && yy=$((y - 1))
dow=$(( (yy + yy/4 - yy/100 + yy/400 + t[mo-1] + d) % 7 ))   # 0 = Sunday
[ "$dow" -eq 0 ] && dow=7

days_match() {
  local spec="$1" part a b
  [[ "$spec" =~ ^[1-7](-[1-7])?(,[1-7](-[1-7])?)*$ ]] || return 1
  local IFS=','
  for part in $spec; do
    if [[ "$part" == *-* ]]; then
      a="${part%-*}"; b="${part#*-}"
      [ "$a" -le "$dow" ] && [ "$dow" -le "$b" ] && return 0
    else
      [ "$part" -eq "$dow" ] && return 0
    fi
  done
  return 1
}

cache="${XDG_CACHE_HOME:-$HOME/.cache}/claude-hooks"
msgs=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" == *'|'*'|'*'|'*'|'* ]] || continue
  # The message is everything after the 4th separator (it may contain '|').
  IFS='|' read -r name days window glob _ <<<"$line"
  message="${line#*|*|*|*|}"
  [ -n "$name" ] && [ -n "$message" ] || continue
  [[ "$window" =~ ^([0-9]{2}):([0-9]{2})-([0-9]{2}):([0-9]{2})$ ]] || continue
  s=$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
  e=$((10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]}))
  # Hours 0-23 for the start; the end may also be exactly 24:00.
  [ "$((10#${BASH_REMATCH[1]}))" -lt 24 ] && [ "$((10#${BASH_REMATCH[2]}))" -lt 60 ] && [ "$((10#${BASH_REMATCH[4]}))" -lt 60 ] || continue
  [ "$e" -le 1440 ] || continue
  [ "$s" -lt "$e" ] || continue
  days_match "$days" || continue
  [ "$nowmin" -ge "$s" ] && [ "$nowmin" -lt "$e" ] || continue
  # shellcheck disable=SC2254
  case "$cwd" in $glob) ;; *) continue ;; esac
  # Marker name: sanitised name plus a checksum of the raw name, so distinct names never collide.
  safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
  sum="$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
  marker="$cache/clockrem.$today.$safe.$sum"
  [ -e "$marker" ] && continue
  if mkdir -p "$cache" 2>/dev/null && ( set -C; : > "$marker" ) 2>/dev/null; then
    # Created by this process: it alone emits. Prune this hook's own markers older than 7 days.
    find "$cache" -maxdepth 1 -type f -name 'clockrem.????-??-??.*' -mtime +7 -delete 2>/dev/null
  elif [ -e "$marker" ]; then
    continue   # another process created it first
  elif [ "$event" != "SessionStart" ]; then
    continue   # cache unwritable: only SessionStart may emit, so prompts cannot repeat it
  fi
  msgs+=("$message")
done < "$conf"

[ "${#msgs[@]}" -gt 0 ] || exit 0
text="$(printf '%s\n' "${msgs[@]}")"; text="${text%$'\n'}"
jq -n --arg e "$event" --arg t "$text" \
  '{systemMessage:("Reminder: " + $t), hookSpecificOutput:{hookEventName:$e, additionalContext:$t}}' 2>/dev/null
exit 0
