#!/usr/bin/env bash
# Payload-driven tests for completion-gate.sh (UserPromptSubmit baseline, Stop check).
# Throwaway repos with local bare origins, stamps made by the real run-checks.sh,
# a temp HOME and temp config. Never touches live ~/.claude files.
# Usage: local-hooks/tests/run-completion-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_COMPLETION_GATE CLAUDE_COMPLETION_GATE_OFF_FILE CLAUDE_COMPLETION_GATE_CONF CLAUDE_CODE_ENTRYPOINT XDG_CACHE_HOME
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
gate="$hooks/completion-gate.sh"; rc="$hooks/run-checks.sh"
off="$HOME/.claude/completion-gate.off"; conf="$HOME/.claude/completion-gate.conf"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }

T="$(mktemp -d "$HOME/t.XXXXXX")"
sid_n=0
nsid() { sid_n=$((sid_n + 1)); echo "s$sid_n"; }
silent_reply="All done. The change is complete and working."
ups() { jq -n --arg s "$1" --arg c "$2" '{hook_event_name:"UserPromptSubmit",session_id:$s,cwd:$c,prompt:"do it"}'; }
stop() { # SID CWD REPLY [ACTIVE] [TRANSCRIPT]
  jq -n --arg s "$1" --arg c "$2" --arg m "$3" --arg a "${4:-false}" --arg t "${5:-}" \
    '{hook_event_name:"Stop",session_id:$s,cwd:$c,stop_hook_active:($a=="true"),last_assistant_message:$m} + (if $t=="" then {} else {transcript_path:$t} end)'
}
# classify PAYLOAD -> silent | block | notice | other:...
classify() {
  local o; o="$(printf '%s' "$1" | bash "$gate" 2>&1)"; printf '%s' "$o" > "$HOME/last_out"
  if [ -z "$o" ]; then echo silent
  elif jq -e '.decision=="block" and (.reason|length>0)' <<<"$o" >/dev/null 2>&1; then echo block
  elif jq -e '.decision==null and (.systemMessage|length>0)' <<<"$o" >/dev/null 2>&1; then echo notice
  else echo "other:$o"; fi
}
check() { local got; got="$(classify "$3")"; [ "$got" = "$2" ] && ok "$1" || bad "$1" "expected $2, got $got"; }

# mkrepo NAME CHECKS: repo with bare origin, one commit on main.
mkrepo() {
  local n="$1" d="$T/$1"
  git init -q --bare -b main "$T/$n.git"; git init -q -b main "$d"
  echo a > "$d/a.txt"; mkdir -p "$d/docs"; echo d > "$d/docs/d.md"; echo r > "$d/README.md"
  if [ -n "${2:-}" ]; then mkdir -p "$d/.claude"; printf '%s\n' "$2" > "$d/.claude/git-checks"; fi
  git -C "$d" add -A; git -C "$d" commit -qm init
  git -C "$d" remote add origin "$T/$n.git"; git -C "$d" push -q origin main
  git -C "$d" fetch -q origin; git -C "$d" remote set-head origin main >/dev/null
}
stamp() { bash "$rc" --dir "$1" >/dev/null 2>&1; }
commit_all() { git -C "$1" add -A; git -C "$1" commit -qm "$2"; }
sleep_tick() { sleep 0.2; }   # file mtimes are compared with the baseline time

# --- turns with no change ---
mkrepo r "true"; r="$T/r"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"
check "no change passes" silent "$(stop "$s" "$r" "$silent_reply")"

# --- docs-only ---
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick
echo more >> "$r/README.md"; echo more >> "$r/docs/d.md"
check "uncommitted docs-only change passes" silent "$(stop "$s" "$r" "$silent_reply")"
commit_all "$r" docs
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick
echo more >> "$r/docs/d.md"; commit_all "$r" docs2
check "committed docs-only change passes" silent "$(stop "$s" "$r" "$silent_reply")"

# --- code change, no stamp ---
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick
echo code >> "$r/a.txt"
check "uncommitted code change, silent reply: block" block "$(stop "$s" "$r" "$silent_reply")"
last_out="$(cat "$HOME/last_out")"
len="$(jq -r .reason <<<"$last_out" | wc -c)"
[ "$len" -lt 450 ] && ok "block reason is short ($len chars)" || bad "block reason length" "$len"
jq -e '.reason|test("Verified:") and test("Not verified:") and test("Blocked:")' <<<"$last_out" >/dev/null && ok "block reason names the accepted statements" || bad "reason text" "$last_out"
check "second Stop of the same turn does not block again (baseline refreshed)" silent "$(stop "$s" "$r" "$silent_reply")"

for stmt in "Verified: npm test passed, 12 tests" "Not verified: tests were not run" "Blocked: waiting on the CI runner" "In progress: the test run is still going" \
  "**Verified:** lint and test passed" "- not verified - no time to run the suite" "Done.

Unverified: no checks were run"; do
  s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
  check "statement accepted: ${stmt%%$'\n'*}" silent "$(stop "$s" "$r" "$stmt")"
done
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
check "the word verified mid-sentence is not a statement" block "$(stop "$s" "$r" "I verified nothing here, but all is done. Not verified is hard to say.")"

# --- stamp ---
mkrepo st "true"; st="$T/st"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$st")"; sleep_tick
echo c >> "$st/a.txt"; commit_all "$st" code
check "committed code, no stamp: block" block "$(stop "$s" "$st" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$st")"; sleep_tick
echo c2 >> "$st/a.txt"; commit_all "$st" code2; stamp "$st"
check "committed code with passing stamp passes" silent "$(stop "$s" "$st" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$st")"; sleep_tick
echo c3 >> "$st/a.txt"
check "stamp for old HEAD does not cover a later uncommitted change" block "$(stop "$s" "$st" "$silent_reply")"
mkrepo bad "false"; bad="$T/bad"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$bad")"; sleep_tick
echo c >> "$bad/a.txt"; commit_all "$bad" code; stamp "$bad"
check "failed stamp does not cover" block "$(stop "$s" "$bad" "$silent_reply")"
mkrepo nochk ""; nochk="$T/nochk"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$nochk")"; sleep_tick; echo c >> "$nochk/a.txt"
check "repo with no checks passes" silent "$(stop "$s" "$nochk" "$silent_reply")"

# --- ignored paths ---
mkrepo ig "true"; ig="$T/ig"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$ig")"; sleep_tick
mkdir -p "$ig/.claude/worktrees/x" "$ig/memory" "$ig/scratchpad"; echo m > "$ig/memory/n.txt"; echo m > "$ig/scratchpad/n.txt"; echo m > "$ig/.claude/worktrees/x/f.txt"
check "memory, scratchpad and .claude paths ignored" silent "$(stop "$s" "$ig" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$ig")"; touch -d '2 hours ago' "$ig/a.txt"; echo pre >> "$ig/a.txt"; touch -d '2 hours ago' "$ig/a.txt"
check "file already dirty before the turn, untouched, passes" silent "$(stop "$s" "$ig" "$silent_reply")"

# --- linked worktrees ---
mkrepo wt "true"; wt="$T/wt"
git -C "$wt" worktree add -q -b feat/pre "$T/wt-pre" origin/main
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$wt")"; sleep_tick
echo code >> "$T/wt-pre/a.txt"
check "uncommitted code change in a linked worktree (cwd untouched): block" block "$(stop "$s" "$wt" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$wt")"; sleep_tick
git -C "$wt" worktree add -q -b feat/new "$T/wt-new" origin/main; echo code >> "$T/wt-new/a.txt"; commit_all "$T/wt-new" newcode
check "worktree created in the turn with a code commit: block" block "$(stop "$s" "$wt" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$wt")"; sleep_tick
git -C "$wt" worktree add -q -b feat/new2 "$T/wt-new2" origin/main; echo code2 >> "$T/wt-new2/a.txt"; commit_all "$T/wt-new2" newcode2; stamp "$T/wt-new2"
check "worktree created in the turn, committed and stamped: passes" silent "$(stop "$s" "$wt" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$T/wt-pre")"; sleep_tick
echo x >> "$wt/a.txt"
check "cwd is itself a linked worktree, change in the main one: block" block "$(stop "$s" "$T/wt-pre" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$wt")"; sleep_tick
git -C "$wt" worktree add -q -b feat/new3 "$T/wt-new3" origin/main
check "worktree created in the turn, no change: passes" silent "$(stop "$s" "$wt" "$silent_reply")"

# --- the turn's tool use (transcript) ---
tx() { # FILE TOOLNAMES...   a user line then an assistant line using the tools
  local f="$1"; shift
  jq -nc '{type:"user",message:{content:"hi"}}' > "$f"
  local n; for n in "$@"; do jq -nc --arg n "$n" '{type:"assistant",message:{content:[{type:"tool_use",name:$n,input:{}}]}}' >> "$f"; jq -nc '{type:"user",message:{content:[{type:"tool_result",content:"x"}]}}' >> "$f"; done
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"done"}]}}' >> "$f"
}
mkrepo tr "true"; trr="$T/tr"
tx "$T/t-read.jsonl" Read Grep; tx "$T/t-agent.jsonl" Read Agent; tx "$T/t-edit.jsonl" Edit
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$trr")"; sleep_tick; echo c >> "$trr/a.txt"
check "turn with only read-only tools skips the scan" silent "$(stop "$s" "$trr" "$silent_reply" false "$T/t-read.jsonl")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$trr")"; sleep_tick; echo c >> "$trr/a.txt"
check "turn that dispatched a subagent is scanned" block "$(stop "$s" "$trr" "$silent_reply" false "$T/t-agent.jsonl")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$trr")"; sleep_tick; echo c >> "$trr/a.txt"
check "turn with an edit tool is scanned" block "$(stop "$s" "$trr" "$silent_reply" false "$T/t-edit.jsonl")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$trr")"; sleep_tick; echo c >> "$trr/a.txt"
check "missing transcript file is scanned" block "$(stop "$s" "$trr" "$silent_reply" false "$T/nope.jsonl")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$trr")"; sleep_tick; echo c >> "$trr/a.txt"
jq -nc '{type:"user",message:{content:"hi"}}' > "$T/t-old.jsonl"; jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Edit",input:{}}]}}' >> "$T/t-old.jsonl"
jq -nc '{type:"user",message:{content:"next question"}}' >> "$T/t-old.jsonl"; jq -nc '{type:"assistant",message:{content:[{type:"text",text:"x"}]}}' >> "$T/t-old.jsonl"
check "only the last turn's tool use counts" silent "$(stop "$s" "$trr" "$silent_reply" false "$T/t-old.jsonl")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$trr")"; sleep_tick; echo c >> "$trr/a.txt"
jq -nc --arg t "Verified: ran the checks" '{type:"assistant",message:{content:[{type:"tool_use",name:"Edit",input:{}},{type:"text",text:$t}]}}' > "$T/t-fb.jsonl"
check "reply read from the transcript when last_assistant_message is absent" silent "$(stop "$s" "$trr" x | jq 'del(.last_assistant_message)' | jq --arg t "$T/t-fb.jsonl" '.transcript_path=$t')"

# --- loop guard, off switches, modes ---
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
check "stop_hook_active never blocks" silent "$(stop "$s" "$r" "$silent_reply" true)"
check "after stop_hook_active the changes are not judged again" silent "$(stop "$s" "$r" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
touch "$off"
check "fresh off-file disables" silent "$(stop "$s" "$r" "$silent_reply")"
touch -d '13 hours ago' "$off"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
check "expired off-file is ignored" block "$(stop "$s" "$r" "$silent_reply")"
rm -f "$off"; mkdir "$off"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
check "off-file that is a directory is ignored" block "$(stop "$s" "$r" "$silent_reply")"
rmdir "$off"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
CLAUDE_COMPLETION_GATE=off check "CLAUDE_COMPLETION_GATE=off disables" silent "$(stop "$s" "$r" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
printf 'MODE=warn\n' > "$conf"
check "MODE=warn gives a notice, not a block" notice "$(stop "$s" "$r" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
printf 'MODE=deny # comment\n' > "$conf"
check "MODE=deny blocks" block "$(stop "$s" "$r" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
printf 'MODE=bogus\n' > "$conf"
check "unknown MODE falls back to deny" block "$(stop "$s" "$r" "$silent_reply")"
rm -f "$conf"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
CLAUDE_CODE_ENTRYPOINT=sdk-cli check "headless sdk-cli exempt" silent "$(stop "$s" "$r" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
CLAUDE_CODE_ENTRYPOINT=cli check "interactive entrypoint is judged" block "$(stop "$s" "$r" "$silent_reply")"

# --- fail open ---
nongit="$T/nongit"; mkdir "$nongit"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$nongit")"
check "non-git cwd passes" silent "$(stop "$s" "$nongit" "$silent_reply")"
[ -z "$(ls "$HOME"/.cache/claude-hooks/completion-gate-"$s".base 2>/dev/null)" ] && ok "non-git cwd writes no baseline" || bad "baseline written for non-git cwd"
echo c >> "$r/a.txt"
check "missing baseline passes" silent "$(stop "never-seen" "$r" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
for f in "$HOME"/.cache/claude-hooks/completion-gate-"$s".base; do printf 'garbage\x00\xff not a baseline' > "$f"; done
check "corrupt baseline passes" silent "$(stop "$s" "$r" "$silent_reply")"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
for f in "$HOME"/.cache/claude-hooks/completion-gate-"$s".base; do : > "$f"; done
check "empty baseline passes" silent "$(stop "$s" "$r" "$silent_reply")"
check "empty input passes" silent ""
check "malformed input passes" silent "not json"
check "Stop without session id passes" silent "$(jq -n --arg c "$r" '{hook_event_name:"Stop",cwd:$c,last_assistant_message:"done"}')"
check "Stop without cwd passes" silent "$(jq -n '{hook_event_name:"Stop",session_id:"zz",last_assistant_message:"done"}')"
check "unknown event passes" silent '{"hook_event_name":"PreToolUse","session_id":"q","cwd":"/"}'

# --- subagent stops ---
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
check "Stop carrying an agent_id is ignored" silent "$(stop "$s" "$r" "$silent_reply" | jq '.agent_id="a1"')"
check "SubagentStop is ignored" silent "$(stop "$s" "$r" "$silent_reply" | jq '.hook_event_name="SubagentStop"')"

# --- UserPromptSubmit baseline step ---
s="s$((++sid_n))"; out="$(bash "$gate" <<<"$(ups "$s" "$r")" 2>&1)"
[ -z "$out" ] && ok "UserPromptSubmit prints nothing" || bad "UserPromptSubmit output" "$out"
[ -n "$(ls "$HOME"/.cache/claude-hooks/completion-gate-"$s".base 2>/dev/null)" ] && ok "baseline stored under the cache dir, keyed by session" || bad "baseline file missing"
s="s$((++sid_n))"; touch "$off"; bash "$gate" <<<"$(ups "$s" "$r")"
[ -z "$(ls "$HOME"/.cache/claude-hooks/completion-gate-"$s".base 2>/dev/null)" ] && ok "baseline not written while the gate is off" || bad "baseline written while off"
rm -f "$off"
s="s$((++sid_n))"; t0=$(date +%s%N); for i in 1 2 3 4 5; do bash "$gate" <<<"$(ups "$s" "$r")"; done; t1=$(date +%s%N)
avg=$(( (t1 - t0) / 5000000 )); [ "$avg" -lt 150 ] && ok "UserPromptSubmit step averages ${avg} ms (< 150)" || bad "UserPromptSubmit slow" "${avg} ms"
s="s$((++sid_n))"; bash "$gate" <<<"$(ups "$s" "$r")"; sleep_tick; echo c >> "$r/a.txt"
t0=$(date +%s%N); bash "$gate" <<<"$(stop "$s" "$r" "$silent_reply")" >/dev/null; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 )); [ "$ms" -lt 3500 ] && ok "Stop run took ${ms} ms (< 3500)" || bad "Stop slow" "${ms} ms"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
