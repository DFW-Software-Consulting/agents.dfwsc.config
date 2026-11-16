#!/usr/bin/env bash
# Payload-driven tests for clock-reminder.sh. Uses a temporary HOME and cache,
# and CLOCK_REMINDER_NOW to pin the clock. All values here are fake.
# Usage: local-hooks/tests/run-clock-reminder-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
unset XDG_CACHE_HOME CLOCK_REMINDER_NOW CLAUDE_CLOCK_REMINDERS_CONF
export XDG_CACHE_HOME="$HOME/cache"
conf="$HOME/reminders.conf"
export CLAUDE_CLOCK_REMINDERS_CONF="$conf"
hook="bash $hooks/clock-reminder.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
# run NOW EVENT CWD -> sets $out
run() { out="$(jq -n --arg e "${2:-UserPromptSubmit}" --arg c "${3:-/work/proj}" '{hook_event_name:$e,cwd:$c}' | CLOCK_REMINDER_NOW="$1" $hook 2>&1)"; }
fires() { run "$2" "${3:-}" "${4:-}"; if jq -e '.systemMessage|startswith("Reminder: ")' >/dev/null 2>&1 <<<"$out"; then ok "$1"; else bad "$1" "out=$out"; fi; }
silent() { run "$2" "${3:-}" "${4:-}"; if [ -z "$out" ]; then ok "$1"; else bad "$1" "out=$out"; fi; }
fresh() { rm -rf "$XDG_CACHE_HOME"; }

# 2026-11-16 is a Monday, 2026-11-21 a Saturday.
cat > "$conf" <<'CONF'
# comment
standup|1-5|09:00-10:00|*|Plan the day.

CONF
fresh
fires "inside window fires" "2026-11-16 09:30"
fresh; fires "start boundary fires" "2026-11-16 09:00"
fresh; silent "end boundary silent" "2026-11-16 10:00"
fresh; fires "one minute before end fires" "2026-11-16 09:59"
fresh; silent "before start silent" "2026-11-16 08:59"
fresh; silent "Saturday silent for 1-5" "2026-11-21 09:30"
fresh; silent "Sunday silent for 1-5" "2026-11-22 09:30"
fresh; fires "Friday fires for 1-5" "2026-11-20 09:30"

printf 'wk|1,3,5|09:00-10:00|*|odd days\n' > "$conf"
fresh; silent "Tuesday silent for 1,3,5" "2026-11-17 09:30"
fresh; fires "Wednesday fires for 1,3,5" "2026-11-18 09:30"
printf 'wk|6-7|09:00-10:00|*|weekend\n' > "$conf"
fresh; fires "Sunday fires for 6-7" "2026-11-22 09:30"

printf 'g|1-5|09:00-10:00|*/proj-a/*|hello\n' > "$conf"
fresh; fires "cwd glob match" "2026-11-16 09:30" UserPromptSubmit /home/x/proj-a/src
fresh; silent "cwd glob mismatch" "2026-11-16 09:30" UserPromptSubmit /home/x/proj-b/src
fresh; silent "empty cwd mismatches specific glob" "2026-11-16 09:30" UserPromptSubmit ""

printf 'once|1-5|09:00-10:00|*|again?\n' > "$conf"
fresh
run "2026-11-16 09:30"; [ -n "$out" ] && ok "first call fires" || bad "first call fires"
silent "second call same day silent" "2026-11-16 09:40"
silent "SessionStart same day silent" "2026-11-16 09:45" SessionStart
fires "next day fires again" "2026-11-17 09:30"
ls "$XDG_CACHE_HOME/claude-hooks" | grep -q '^clockrem.2026-11-16.once' && ok "marker has date and name" || bad "marker naming" "$(ls "$XDG_CACHE_HOME/claude-hooks")"

printf 'one|1-5|09:00-10:00|*|First thing.\ntwo|1-5|09:00-10:00|*|Second thing.\nlate|1-5|15:00-16:00|*|Not yet.\n' > "$conf"
fresh; run "2026-11-16 09:30"
if jq -e '(.systemMessage=="Reminder: First thing.\nSecond thing.") and (.hookSpecificOutput.additionalContext=="First thing.\nSecond thing.")' >/dev/null 2>&1 <<<"$out"; then ok "two due reminders joined"; else bad "join" "out=$out"; fi
[ "$(grep -c '^{' <<<"$out")" -le 1 ] && ok "single JSON object" || bad "multiple objects"

rm -f "$conf"; fresh
silent "no config silent" "2026-11-16 09:30"
[ ! -e "$XDG_CACHE_HOME" ] && ok "no config writes nothing" || bad "cache created without config"

cat > "$conf" <<'CONF'
garbage line
only|three|fields
bad-days|9|09:00-10:00|*|nope
bad-time|1-5|25:00-26:00|*|nope
backwards|1-5|10:00-09:00|*|nope
midnight|1-5|23:00-01:00|*|nope
bad-glob-empty-name||09:00-10:00|*|nope
|1-5|09:00-10:00|*|noname
good|1-5|09:00-10:00|*|Valid one.
CONF
fresh; run "2026-11-16 09:30"
[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>/dev/null)" = "Valid one." ] && ok "malformed lines skipped, valid works" || bad "malformed" "out=$out"

canary="$HOME/canary"
cat > "$conf" <<CONF
inj|1-5|09:00-10:00|*|\$(touch $canary) \`touch $canary\`
\$(touch $canary)|1-5|09:00-10:00|*|name sub
CONF
fresh; run "2026-11-16 09:30"
[ ! -e "$canary" ] && ok "command substitution in config not executed" || bad "config executed code"
jq -e '.systemMessage|contains("$(touch")' >/dev/null 2>&1 <<<"$out" && ok "substitution text kept literally" || bad "literal text" "out=$out"

printf 'ev|1-5|09:00-10:00|*|evt\n' > "$conf"
fresh; run "2026-11-16 09:30" SessionStart
[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = "SessionStart" ] && ok "SessionStart hookEventName" || bad "SessionStart name" "$out"
fresh; run "2026-11-16 09:30" UserPromptSubmit
[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = "UserPromptSubmit" ] && ok "UserPromptSubmit hookEventName" || bad "UPS name" "$out"
fresh; silent "other event silent" "2026-11-16 09:30" PreToolUse

printf 'q|1-5|09:00-10:00|*|Say "hi" | caf\xc3\xa9 \xe2\x9c\x93 \\ back\n' > "$conf"
fresh; run "2026-11-16 09:30"
[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>/dev/null)" = 'Say "hi" | café ✓ \ back' ] && ok "quotes, pipe, unicode, backslash valid JSON" || bad "special chars" "out=$out"

# --- review items ---
cat > "$conf" <<'CONF'
bad1|1-2-3|09:00-10:00|*|nope
bad2|1-3-5|09:00-10:00|*|nope
good|1-5|09:00-10:00|*|Valid one.
CONF
fresh; out="$(jq -n '{hook_event_name:"UserPromptSubmit",cwd:"/w"}' | CLOCK_REMINDER_NOW="2026-11-16 09:30" $hook 2>"$HOME/err")"
[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>/dev/null)" = "Valid one." ] && [ ! -s "$HOME/err" ] && ok "1-2-3 and 1-3-5 skipped, no stderr, valid line fires" || bad "bad days spec" "out=$out err=$(cat "$HOME/err")"

printf 'conc|1-5|09:00-10:00|*|Once only.\n' > "$conf"
fresh; mkdir -p "$HOME/conc"
for i in 1 2 3 4 5 6; do
  ( jq -n '{hook_event_name:"SessionStart",cwd:"/w"}' | CLOCK_REMINDER_NOW="2026-11-16 09:30" $hook > "$HOME/conc/$i.out" 2>&1 ) &
done
wait
n="$(cat "$HOME"/conc/*.out | grep -c systemMessage)"
[ "$n" -eq 1 ] && ok "concurrent runs emit exactly once" || bad "concurrent emit count" "$n"

printf 'late|1-7|23:00-24:00|*|To midnight.\n' > "$conf"
fresh; fires "end 24:00 fires at 23:59" "2026-11-16 23:59"
printf 'bad|1-7|24:00-24:00|*|nope\n' > "$conf"
fresh; silent "start 24:00 malformed" "2026-11-16 23:59"
printf 'bad|1-7|23:00-24:01|*|nope\n' > "$conf"
fresh; silent "end 24:01 malformed" "2026-11-16 23:59"

printf 'a b|1-5|09:00-10:00|*|Space name.\na_b|1-5|09:00-10:00|*|Underscore name.\n' > "$conf"
fresh; run "2026-11-16 09:30"
[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")" = $'Space name.\nUnderscore name.' ] && ok "names 'a b' and 'a_b' fire independently" || bad "name collision" "$out"

printf 'ro|1-5|09:00-10:00|*|Cache locked.\n' > "$conf"
fresh; mkdir -p "$XDG_CACHE_HOME"; chmod 500 "$XDG_CACHE_HOME"
if ( : > "$XDG_CACHE_HOME/probe" ) 2>/dev/null; then
  echo "skip - cache dir stays writable (running as root?), unwritable-cache tests skipped"
else
  run "2026-11-16 09:30" SessionStart
  jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 <<<"$out" && ok "unwritable cache: SessionStart fires" || bad "unwritable SessionStart" "$out"
  silent "unwritable cache: UserPromptSubmit silent" "2026-11-16 09:30" UserPromptSubmit
fi
chmod 700 "$XDG_CACHE_HOME"; rm -rf "$XDG_CACHE_HOME"

printf 'pr|1-5|09:00-10:00|*|Prune test.\n' > "$conf"
fresh; d="$XDG_CACHE_HOME/claude-hooks"; mkdir -p "$d"
: > "$d/clockrem.2026-11-08.old.1"; : > "$d/clockrem.2026-11-14.recent.1"; : > "$d/unrelated.file"
touch -d '8 days ago' "$d/clockrem.2026-11-08.old.1" "$d/unrelated.file"; touch -d '2 days ago' "$d/clockrem.2026-11-14.recent.1"
run "2026-11-16 09:30"
[ ! -e "$d/clockrem.2026-11-08.old.1" ] && [ -e "$d/clockrem.2026-11-14.recent.1" ] && [ -e "$d/unrelated.file" ] && ok "8-day-old marker pruned, 2-day kept, foreign file kept" || bad "pruning" "$(ls "$d")"

for badin in '' 'not json' '[1]'; do
  fresh; out="$(printf '%s' "$badin" | CLOCK_REMINDER_NOW="2026-11-16 09:30" $hook 2>&1)"; rc=$?
  [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "silent on input: ${badin:-<empty>}" || bad "input '$badin'" "rc=$rc out=$out"
done
fresh; out="$(echo '{"hook_event_name":"UserPromptSubmit"}' | CLOCK_REMINDER_NOW="garbage" $hook 2>&1)"
[ -z "$out" ] && ok "bad CLOCK_REMINDER_NOW silent" || bad "bad now" "$out"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
