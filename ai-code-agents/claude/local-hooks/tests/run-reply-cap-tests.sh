#!/usr/bin/env bash
# Payload-driven tests for enforce-response-cap.sh (Stop) and reply-cap-prompt.sh
# (UserPromptSubmit). Temporary HOME; markers go under the scratchpad dir
# (override with SCRATCH) or the temp HOME's cache. Never touches live files.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
scratch="${SCRATCH:-/home/messyginger0804/.cache/tmp/claude-1000/-home-messyginger0804/7d9c7718-6dce-42d0-bf45-720a9e7269da/scratchpad}"
mkdir -p "$scratch"; export TMPDIR="$scratch"
unset XDG_CACHE_HOME
run="$(date +%s)-$$"

cap="$hooks/enforce-response-cap.sh"; pr="$hooks/reply-cap-prompt.sh"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1 ${2:-}"; }
call() { out="$(printf '%s' "$2" | bash "$1" 2>&1)"; rc=$?; }
filler() { head -c "$1" /dev/zero | tr '\0' 'y'; }

stop() { jq -n --arg m "$1" --arg s "$2" --arg a "${3:-false}" --arg d "${4-$scratch}" \
  '{hook_event_name:"Stop",session_id:$s,stop_hook_active:($a=="true"),last_assistant_message:$m} + (if $d=="" then {} else {scratchpad_dir:$d} end)'; }
up() { jq -n --arg p "$1" --arg s "$2" --arg d "${3-$scratch}" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p} + (if $d=="" then {} else {scratchpad_dir:$d} end)'; }
# expect_stop NAME PAYLOAD block|none
expect_stop() {
  call "$cap" "$2"
  local got=none
  if [ -n "$out" ]; then
    jq -e '.decision=="block" and (.reason|length>0)' <<<"$out" >/dev/null 2>&1 && got=block || got=garbage
  fi
  [ "$rc" -eq 0 ] && [ "$got" = "$3" ] && ok "$1" || bad "$1" "(expected $3, got $got, rc=$rc) $out"
}
mdir="$HOME/.cache/claude-hooks"
marker() { echo "$mdir/reply-cap-approval-$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')"; }
long="$(filler 1500)"; short="$(filler 500)"

# --- measuring from last_assistant_message ---
expect_stop "under the cap allowed" "$(stop "$short" "a1-$run")" none
expect_stop "exactly at the cap allowed" "$(stop "$(filler 1200)" "a2-$run")" none
expect_stop "over the cap blocked" "$(stop "$long" "a3-$run")" block
grep -q '1500 characters' <<<"$(jq -r .reason <<<"$out")" && ok "block reason reports the length" || bad "block reason length" "$out"
jq -e . <<<"$out" >/dev/null 2>&1 && ok "block output is valid JSON" || bad "block output JSON"
expect_stop "code blocks excluded from the count" "$(stop "$short"$'\n```\n'"$(filler 3000)"$'\n```\n'"$short" "a4-$run")" none
expect_stop "text outside code blocks still counted" "$(stop "$long"$'\n```\nx\n```' "a5-$run")" block
expect_stop "stop_hook_active allows" "$(stop "$long" "a6-$run" true)" none

# --- transcript fallback ---
tr_dir="$HOME/tr"; mkdir -p "$tr_dir"
mk_tr() { # file text
  jq -nc --arg t "$2" '{type:"user",message:{content:"hi"}}' >"$1"
  jq -nc --arg t "$2" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >>"$1"
}
mk_tr "$tr_dir/long.jsonl" "$long"; mk_tr "$tr_dir/short.jsonl" "$short"
fb() { jq -n --arg t "$1" --arg s "$2" '{hook_event_name:"Stop",session_id:$s,transcript_path:$t}'; }
expect_stop "fallback: long transcript blocked" "$(fb "$tr_dir/long.jsonl" "b1-$run")" block
expect_stop "fallback: short transcript allowed" "$(fb "$tr_dir/short.jsonl" "b2-$run")" none
expect_stop "fallback: missing transcript file allowed" "$(fb "$tr_dir/nope.jsonl" "b3-$run")" none
expect_stop "field wins over transcript" "$(fb "$tr_dir/long.jsonl" "b4-$run" | jq --arg m "$short" '.last_assistant_message=$m')" none
# big transcript: long reply at the end of a file over the 400000-byte tail window
{ for i in $(seq 1 300); do jq -nc --arg t "$(filler 2000)" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; done; jq -nc --arg t "$long" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; } >"$tr_dir/big.jsonl"
expect_stop "fallback: big transcript reads the tail" "$(fb "$tr_dir/big.jsonl" "b5-$run")" block
{ jq -nc --arg t "$long" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; for i in $(seq 1 300); do jq -nc --arg t "$(filler 2000)" '{type:"user",message:{content:$t}}'; done; jq -nc --arg t "$short" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; } >"$tr_dir/big2.jsonl"
expect_stop "fallback: big transcript last message short allowed" "$(fb "$tr_dir/big2.jsonl" "b6-$run")" none
printf 'garbage line\n' >>"$tr_dir/short.jsonl"
expect_stop "fallback: junk lines skipped" "$(fb "$tr_dir/short.jsonl" "b7-$run")" none

# --- approval phrases set a marker ---
n=0
yes_phrases=("go long" "No Limit" "give me the full writeup" "FULL WRITE-UP please" "I need more detail." "expand" "  Expand  " " Expand. " "explain the gate, go long" "go long on this one" "in more detail please." "Tell me about it, Full Write-Up, thanks!" $'first line\ngo long\nlast line' $'do the thing\n  More detail.  \nok' $'```\nx\n```\ngo long' "GO LONG")
for ph in "${yes_phrases[@]}"; do
  n=$((n + 1)); s="ph$n-$run"; call "$pr" "$(up "$ph" "$s")"
  [ "$rc" -eq 0 ] && [ "$(cat "$(marker "$s")" 2>/dev/null)" = oneshot ] && ok "phrase sets one-shot marker: '$ph'" || bad "phrase '$ph'" "rc=$rc out=$out"
done
no_phrases=("expand the function" "going longer" "no limits" "more details" "please explain" "nolimit" "add more detail to the docs" "there is no limit on retries" "what is the rate limit on this API" "we should go long on the stock" $'say go long here\nand more' $'```\ngo long\n```\nhello' $'before\n```\nmore detail\n```' "expand it please" "set the limit off for the rate limiter" "go long-term")
for ph in "${no_phrases[@]}"; do
  n=$((n + 1)); s="np$n-$run"; call "$pr" "$(up "$ph" "$s")"
  [ ! -e "$(marker "$s")" ] && ok "no marker for '$ph'" || bad "unexpected marker for '$ph'"
done
n=0
for ph in "limit off" "Limit OFF" "  limit off.  " "limit off!"; do
  n=$((n + 1)); s="lo$n-$run"; call "$pr" "$(up "$ph" "$s")"
  [ "$(cat "$(marker "$s")" 2>/dev/null)" = session ] && ok "whole prompt '$ph' sets session marker" || bad "limit off '$ph'"
done
for ph in "set the limit off for the rate limiter" "please turn limit off now" "limit off and go on" $'limit off\nplease'; do
  n=$((n + 1)); s="lox$n-$run"; call "$pr" "$(up "$ph" "$s")"
  [ ! -e "$(marker "$s")" ] && ok "'$ph' does not set session marker" || bad "limit off in sentence '$ph'"
done
# "limit on" clears only as a whole prompt
for ph in "what is the rate limit on this API" "there is no limit on retries" "limit on retries"; do
  n=$((n + 1)); s="lon$n-$run"; call "$pr" "$(up "limit off" "$s")"; call "$pr" "$(up "$ph" "$s")"
  [ "$(cat "$(marker "$s")" 2>/dev/null)" = session ] && ok "'$ph' keeps the session approval" || bad "'$ph' cleared approval"
done
for ph in "limit on" "Limit On." "  LIMIT ON  "; do
  n=$((n + 1)); s="lonc$n-$run"; call "$pr" "$(up "limit off" "$s")"; call "$pr" "$(up "$ph" "$s")"
  [ ! -e "$(marker "$s")" ] && ok "whole prompt '$ph' clears approval" || bad "'$ph' did not clear"
done
s="lc-$run"; call "$pr" "$(up "limit once" "$s")"; [ ! -e "$(marker "$s")" ] && ok "'limit once' is not 'limit on'" || bad "limit once"

# --- stale one-shot ---
s="st-$run"; call "$pr" "$(up "go long" "$s")"
call "$pr" "$(up "now fix the bug" "$s")"
[ ! -e "$(marker "$s")" ] && ok "next prompt removes a left-over one-shot" || bad "stale one-shot kept"
expect_stop "stale one-shot: long reply to unrelated prompt blocked" "$(stop "$long" "$s")" block
s="st2-$run"; call "$pr" "$(up "limit off" "$s")"; call "$pr" "$(up "fix the bug" "$s")"
[ "$(cat "$(marker "$s")")" = session ] && ok "session approval survives later prompts" || bad "session approval lost"
s="st3-$run"; call "$pr" "$(up "go long" "$s")"; call "$pr" "$(up "go long again" "$s")"
[ "$(cat "$(marker "$s")")" = oneshot ] && ok "new approving prompt re-arms the one-shot" || bad "re-arm"

# --- reminders ---
call "$pr" "$(up "hello" "r1-$run")"; plain="$out"
[ "$rc" -eq 0 ] && grep -q '1200' <<<"$plain" && grep -qi 'code blocks' <<<"$plain" && [ "$(wc -l <<<"$plain")" -eq 1 ] && ok "plain reminder: one line with cap and counting rule" || bad "plain reminder" "$plain"
call "$pr" "$(up "go long" "r2-$run")"; one="$out"
call "$pr" "$(up "limit off" "r3-$run")"; sess="$out"
grep -qi 'this turn' <<<"$one" && ! grep -q 'Reply length cap' <<<"$one" && ok "one-shot reminder says approved for this turn" || bad "one-shot reminder" "$one"
grep -q 'limit on' <<<"$sess" && ok "session reminder mentions limit on" || bad "session reminder" "$sess"
[ "$plain" != "$one" ] && [ "$one" != "$sess" ] && [ "$plain" != "$sess" ] && ok "reminder text differs by state" || bad "reminders identical"

# --- enforcement with markers ---
s="e1-$run"; call "$pr" "$(up "go long" "$s")"
expect_stop "one-shot allows one long reply" "$(stop "$long" "$s")" none
[ ! -e "$(marker "$s")" ] && ok "one-shot marker removed after use" || bad "marker still present"
expect_stop "long reply after one-shot blocked again" "$(stop "$long" "$s")" block
s="e2-$run"; call "$pr" "$(up "expand" "$s")"
expect_stop "one-shot cleared by a short reply" "$(stop "$short" "$s")" none
[ ! -e "$(marker "$s")" ] && ok "marker gone after short reply" || bad "marker kept after short reply"
expect_stop "later long reply blocked (no carry-over)" "$(stop "$long" "$s")" block
s="e3-$run"; call "$pr" "$(up "limit off" "$s")"
expect_stop "limit off: first long reply allowed" "$(stop "$long" "$s")" none
expect_stop "limit off: second long reply allowed" "$(stop "$long" "$s")" none
[ -e "$(marker "$s")" ] && ok "session marker kept" || bad "session marker lost"
call "$pr" "$(up "limit on" "$s")"
[ ! -e "$(marker "$s")" ] && ok "limit on removes the marker" || bad "limit on kept marker"
expect_stop "limit on: long reply blocked again" "$(stop "$long" "$s")" block
call "$pr" "$(up "limit on" "$s")"; grep -q 'Reply length cap' <<<"$out" && ok "limit on gives the plain reminder" || bad "limit on reminder" "$out"
s="e4-$run"; call "$pr" "$(up "go long" "$s")"
expect_stop "stop_hook_active leaves the marker alone" "$(stop "$long" "$s" true)" none
[ -e "$(marker "$s")" ] && ok "marker kept when stop_hook_active" || bad "marker consumed on stop_hook_active"

# --- session isolation and id sanitising ---
call "$pr" "$(up "go long" "iso1-$run")"
expect_stop "other session does not share the marker" "$(stop "$long" "iso2-$run")" block
expect_stop "own session still approved" "$(stop "$long" "iso1-$run")" none
s="../a/b/c-$run"; call "$pr" "$(up "go long" "$s")"
[ "$(cat "$mdir/reply-cap-approval-___a_b_c-$run" 2>/dev/null)" = oneshot ] && ok "slashes in session_id sanitised in marker name" || bad "sanitise"
[ ! -e "$scratch/../a" ] && ok "no path escape" || bad "path escape"
expect_stop "sanitised session id approves" "$(stop "$long" "$s")" none
call "$pr" "$(up "go long" "")"; ls "$mdir"/reply-cap-approval-?* 2>/dev/null | grep -qE 'approval-$'  && bad "marker written without session_id" || ok "no marker without session_id"

# --- one canonical marker location ---
call "$pr" "$(up "go long" "c1-$run" "")"
[ "$(cat "$HOME/.cache/claude-hooks/reply-cap-approval-c1-$run" 2>/dev/null)" = oneshot ] && ok "marker under HOME cache without scratchpad_dir" || bad "cache marker"
call "$pr" "$(up "go long" "c3-$run")"
[ "$(cat "$HOME/.cache/claude-hooks/reply-cap-approval-c3-$run" 2>/dev/null)" = oneshot ] && [ ! -e "$scratch/reply-cap-approval-c3-$run" ] && ok "scratchpad_dir does not move the marker" || bad "marker in scratchpad"
expect_stop "prompt had scratchpad_dir, Stop does not: approval found" "$(stop "$long" "c3-$run" false "")" none
call "$pr" "$(up "go long" "c4-$run" "")"
expect_stop "Stop has scratchpad_dir, prompt did not: approval found" "$(stop "$long" "c4-$run")" none
export XDG_CACHE_HOME="$HOME/xdg"
call "$pr" "$(up "go long" "c2-$run" "")"
[ -f "$HOME/xdg/claude-hooks/reply-cap-approval-c2-$run" ] && ok "XDG_CACHE_HOME honoured" || bad "xdg marker"
unset XDG_CACHE_HOME

# --- shared file missing: old behaviour ---
iso="$(mktemp -d)"; cp "$cap" "$pr" "$iso/"
s="m1-$run"; call "$pr" "$(up "go long" "$s")"
call "$iso/enforce-response-cap.sh" "$(stop "$long" "$s")"
jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && ok "no shared file: marker ignored, long reply blocked" || bad "no shared file block" "$out"
call "$iso/enforce-response-cap.sh" "$(stop "$short" "$s")"; [ -z "$out" ] && ok "no shared file: short reply allowed" || bad "no shared file short" "$out"
jq -e '.reason|test("1200-character")' <<<"$(printf '%s' "$(stop "$long" "m2-$run")" | bash "$iso/enforce-response-cap.sh")" >/dev/null 2>&1 && ok "no shared file: cap is 1200" || bad "no shared file cap"
s="m3-$run"; call "$iso/reply-cap-prompt.sh" "$(up "go long" "$s")"
[ "$rc" -eq 0 ] && grep -q '1200' <<<"$out" && [ ! -e "$(marker "$s")" ] && ok "prompt script without shared file: plain reminder, no marker" || bad "prompt no shared" "$out"

# --- fail open: malformed and empty stdin ---
for s in "$cap" "$pr" "$iso/enforce-response-cap.sh" "$iso/reply-cap-prompt.sh"; do
  n="$(basename "$s")"
  for in in '' 'not json {' '[]' '"str"' '{}' '{"prompt":5}' '{"last_assistant_message":5}'; do
    call "$s" "$in"; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "$n silent on stdin: ${in:-<empty>}" || bad "$n on stdin '$in'" "rc=$rc out=$out"
  done
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
