#!/usr/bin/env bash
# Payload-driven tests for context-docs-start.sh, require-acceptance-criteria.sh
# and handback-gate.sh. Temporary HOME and git repos; state files go under the
# scratchpad dir (override with SCRATCH). Never touches live ~/.claude files.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
scratch="${SCRATCH:-/home/messyginger0804/.cache/tmp/claude-1000/-home-messyginger0804/7d9c7718-6dce-42d0-bf45-720a9e7269da/scratchpad}"
mkdir -p "$scratch"; export TMPDIR="$scratch"
unset CLAUDE_ACCEPTANCE_GATE
run="$(date +%s)-$$"   # unique agent ids per run, state files persist in scratch

start="$hooks/context-docs-start.sh"; req="$hooks/require-acceptance-criteria.sh"; hb="$hooks/handback-gate.sh"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1 ${2:-}"; }

# Repos
opted="$HOME/opted"; plain="$HOME/plain"; nonrepo="$HOME/nonrepo"; big="$HOME/big"
for r in "$opted" "$plain" "$big"; do mkdir -p "$r"; git -C "$r" init -q; done
mkdir -p "$nonrepo" "$opted/docs/context" "$opted/sub" "$big/docs/context"
printf -- '- [auth.md](auth.md) : read when changing auth\n' >"$opted/docs/context/INDEX.md"
head -c 5000 /dev/zero | tr '\0' 'x' >"$big/docs/context/INDEX.md"

# call SCRIPT PAYLOAD -> sets out, rc
call() { out="$(printf '%s' "$2" | bash "$1" 2>&1)"; rc=$?; }
# expect NAME SCRIPT PAYLOAD KIND  (KIND: none | ctx | deny | block)
expect() {
  local name="$1" script="$2" payload="$3" kind="$4" got=none
  call "$script" "$payload"
  if [ -n "$out" ]; then
    if jq -e '.hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.hookEventName=="PreToolUse" and (.hookSpecificOutput.permissionDecisionReason|length>0)' <<<"$out" >/dev/null 2>&1; then got=deny
    elif jq -e '.decision=="block" and (.reason|length>0)' <<<"$out" >/dev/null 2>&1; then got=block
    elif jq -e '.hookSpecificOutput.hookEventName and (.hookSpecificOutput.additionalContext|length>0)' <<<"$out" >/dev/null 2>&1; then got=ctx
    else got=garbage; fi
  fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$kind" ]; then ok "$name"; else bad "$name" "(expected $kind, got $got, rc=$rc) $out"; fi
}
ctx_of() { jq -r '.hookSpecificOutput.additionalContext' <<<"$out"; }
ss() { jq -n --arg c "$1" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}'; }
sa() { jq -n --arg c "$1" --arg t "$2" '{hook_event_name:"SubagentStart",cwd:$c,agent_id:"x",agent_type:$t}'; }

# --- context-docs-start.sh ---
expect "SessionStart opted-in injects" "$start" "$(ss "$opted")" ctx
grep -q 'read when changing auth' <<<"$(ctx_of)" && grep -q 'errors.md' <<<"$(ctx_of)" && ok "SessionStart content has INDEX and lead-in" || bad "SessionStart content"
[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = SessionStart ] && ok "SessionStart event name echoed" || bad "event name"
expect "SessionStart from subdirectory of opted repo injects" "$start" "$(ss "$opted/sub")" ctx
expect "SessionStart plain repo silent" "$start" "$(ss "$plain")" none
expect "SessionStart non-repo silent" "$start" "$(ss "$nonrepo")" none
expect "SessionStart missing cwd silent" "$start" '{"hook_event_name":"SessionStart"}' none
expect "SessionStart oversize INDEX truncated" "$start" "$(ss "$big")" ctx
c="$(ctx_of)"; grep -q 'truncated' <<<"$c" && [ "$(grep -oE 'x+' <<<"$c" | awk '{ if (length($0) > m) m = length($0) } END { print m }')" -eq 3000 ] && ok "truncation at 3000 chars and says so" || bad "truncation"
expect "SubagentStart executor opted-in" "$start" "$(sa "$opted" executor)" ctx
c="$(ctx_of)"; grep -q 'read when changing auth' <<<"$c" && grep -q 'Context docs: updated' <<<"$c" && grep -q 'Acceptance check' <<<"$c" && ok "executor gets INDEX plus both standing instructions" || bad "executor content"
expect "SubagentStart executor plain repo still gets instructions" "$start" "$(sa "$plain" executor)" ctx
c="$(ctx_of)"; grep -q 'Context docs: updated' <<<"$c" && grep -q 'Acceptance check' <<<"$c" && ! grep -q 'read when changing auth' <<<"$c" && ok "executor plain: instructions only" || bad "executor plain content"
expect "SubagentStart executor non-repo gets instructions" "$start" "$(sa "$nonrepo" executor)" ctx
expect "SubagentStart Explore opted-in gets INDEX" "$start" "$(sa "$opted" Explore)" ctx
c="$(ctx_of)"; grep -q 'read when changing auth' <<<"$c" && ! grep -q 'Acceptance check' <<<"$c" && ! grep -q 'Context docs: updated' <<<"$c" && ok "Explore gets only INDEX content" || bad "Explore content"
expect "SubagentStart Explore plain repo silent" "$start" "$(sa "$plain" Explore)" none
expect "SubagentStart Explore non-repo silent" "$start" "$(sa "$nonrepo" Explore)" none
CLAUDE_ACCEPTANCE_GATE=off call "$start" "$(sa "$plain" executor)"
c="$(ctx_of)"; grep -q 'Context docs: updated' <<<"$c" && ! grep -q 'Acceptance check' <<<"$c" && ok "gate off drops acceptance instruction" || bad "gate off start"

# --- require-acceptance-criteria.sh ---
ag() { jq -n --arg p "$1" --arg t "$2" --arg id "${3:-}" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:({prompt:$p,description:"d",model:"haiku"} + (if $t=="" then {} else {subagent_type:$t} end))} + (if $id=="" then {} else {agent_id:$id} end)'; }
expect "Agent without criteria denied" "$req" "$(ag $'Do the thing\nnow' executor)" deny
expect "Agent with '## Done when' allowed" "$req" "$(ag $'Do it\n\n## Done when\n- x' executor)" none
expect "Agent with 'Acceptance criteria:' allowed" "$req" "$(ag $'Do it\nAcceptance criteria:\n- x' executor)" none
expect "Agent with bold '**Definition of done**' allowed" "$req" "$(ag $'Do it\n**Definition of done**\n- x' executor)" none
expect "Agent with 'Done means' allowed" "$req" "$(ag $'Do it\ndone means x' executor)" none
expect "Agent criteria phrase mid-sentence still denied" "$req" "$(ag 'tell me when done when finished' executor)" deny
expect "Exempt type without criteria allowed" "$req" "$(ag 'find it' Explore)" none
expect "Empty subagent_type counts as non-exempt" "$req" "$(ag 'do it' '')" deny
expect "Agent call inside a subagent allowed" "$req" "$(ag 'do it' executor sub1)" none
CLAUDE_ACCEPTANCE_GATE=off call "$req" "$(ag 'do it' executor)"; [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "gate off allows Agent without criteria" || bad "gate off req"

# --- handback-gate.sh ---
good=$'Did the work.\n\nAcceptance check\n- tests pass : met : ran suite\n- docs updated : met : edited\n\nContext docs: no change needed, tiny fix'
pre() { jq -n --arg m "$1" --arg id "$2" --arg t "${3:-executor}" --arg s "$scratch" '{hook_event_name:"PreToolUse",tool_name:"SubagentHandback",agent_id:$id,agent_type:$t,scratchpad_dir:$s,tool_input:{message:$m}}'; }
stp() { jq -n --arg m "$1" --arg id "$2" --arg a "${3:-false}" --arg t "${4:-executor}" --arg s "$scratch" '{hook_event_name:"SubagentStop",agent_id:$id,agent_type:$t,scratchpad_dir:$s,stop_hook_active:($a=="true"),last_assistant_message:$m}'; }
expect "handback with full section and Context docs allowed" "$hb" "$(pre "$good" "p1-$run")" none
expect "handback with markdown heading section allowed" "$hb" "$(pre $'x\n## Acceptance check\n- a : met : e\n\nContext docs: none in this repo' "p1b-$run")" none
expect "handback without Acceptance check sent back" "$hb" "$(pre $'Done.\nContext docs: none in this repo' "p2-$run")" deny
grep -q 'Acceptance check' <<<"$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" && ok "reason names the missing section" || bad "reason text"
expect "handback with 'not met' sent back" "$hb" "$(pre $'x\nAcceptance check\n- a : met : e\n- b : not met : failed\n\nContext docs: none in this repo' "p3-$run")" deny
grep -q 'blocks' <<<"$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" && ok "not met reason asks what blocks" || bad "not met reason"
expect "handback with literal 'met | not met' template line not flagged" "$hb" "$(pre $'x\nAcceptance check\n- a : met | not met : e\n\nContext docs: none in this repo' "p3b-$run")" none
expect "handback missing Context docs line sent back" "$hb" "$(pre $'x\nAcceptance check\n- a : met : e' "p4-$run")" deny
expect "handback missing both sent back (combined)" "$hb" "$(pre 'nothing' "p5-$run")" deny
r="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")"; grep -q 'Acceptance check' <<<"$r" && grep -q 'Context docs' <<<"$r" && ok "combined reason lists both problems" || bad "combined reason"
id="cap-$run"; badmsg='no report format'
expect "attempt 1 sent back" "$hb" "$(pre "$badmsg" "$id")" deny
expect "attempt 2 sent back" "$hb" "$(pre "$badmsg" "$id")" deny
expect "attempt 3 allowed by the cap" "$hb" "$(pre "$badmsg" "$id")" none
expect "handback exempt agent type allowed" "$hb" "$(pre "$badmsg" "ex-$run" Explore)" none
expect "handback from main session (no agent_id) allowed" "$hb" "$(pre "$badmsg" "")" none
CLAUDE_ACCEPTANCE_GATE=off call "$hb" "$(pre "$badmsg" "off-$run")"; [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "gate off allows handback" || bad "gate off hb"
expect "SubagentStop bad message blocked" "$hb" "$(stp "$badmsg" "s1-$run")" block
expect "SubagentStop good message allowed" "$hb" "$(stp "$good" "s2-$run")" none
expect "SubagentStop with stop_hook_active allowed" "$hb" "$(stp "$badmsg" "s3-$run" true)" none
expect "SubagentStop exempt type allowed" "$hb" "$(stp "$badmsg" "s4-$run" false Plan)" none
expect "SubagentStop capped after two blocks" "$hb" "$(stp "$badmsg" "s5-$run")" block
expect "SubagentStop second block" "$hb" "$(stp "$badmsg" "s5-$run")" block
expect "SubagentStop third allowed by cap" "$hb" "$(stp "$badmsg" "s5-$run")" none
expect "handback passes" "$hb" "$(pre "$good" "s6-$run")" none
expect "SubagentStop after passed handback allowed without re-check" "$hb" "$(stp "$badmsg" "s6-$run")" none
# state fallback to XDG cache when scratchpad_dir absent
export XDG_CACHE_HOME="$HOME/cache"
call "$hb" "$(pre "$badmsg" "fb-$run" | jq 'del(.scratchpad_dir)')"
ls "$XDG_CACHE_HOME"/claude-hooks/handback-fb-* >/dev/null 2>&1 && ok "state falls back to XDG cache dir" || bad "xdg fallback"
unset XDG_CACHE_HOME

# --- review fixes: Context docs variants (item 1) ---
n=0
okhdr=$'Acceptance check\n- a : met : e\n\n'
for cd in '- Context docs: none' '> Context docs: updated x' '**Context docs**: none' '**Context docs:** updated x' 'Context docs : none' 'context docs - none' '* Context docs: none' '1. Context docs: none' 'Context docs – none' 'Context docs — none' '__Context docs__: none'; do
  n=$((n + 1)); expect "Context docs variant allowed: $cd" "$hb" "$(pre "$okhdr$cd" "cdv$n-$run")" none
done
expect "Context docs mid-sentence still sent back" "$hb" "$(pre "${okhdr}I updated the Context docs: none needed" "cdm-$run")" deny

# --- header variants (item 4) ---
n=0
for h in '## Acceptance check' '**Acceptance check**' 'Acceptance check:' '- Acceptance check' '1. Acceptance check' '### Acceptance check (4/4)' 'Acceptance checks' '# ACCEPTANCE CHECK'; do
  n=$((n + 1)); expect "header variant allowed: $h" "$hb" "$(pre "$h"$'\n- a : met : e\n\nContext docs: none' "hv$n-$run")" none
done
expect "header variant with unmet line sent back" "$hb" "$(pre $'### Acceptance check (1/2)\n- a : not met : e\nContext docs: none' "hvu-$run")" deny

# --- status parsing (item 2) ---
n=0
st() { n=$((n + 1)); expect "$1" "$hb" "$(pre $'Acceptance check\n'"$2"$'\n\nContext docs: none' "st$n-$run")" "$3"; }
st "met line with 'not met' in evidence is met" '- X : met : the old method was not met by tests' none
st "met with 'method' and 'metric' words" '- parameters and symmetric metric : met : method ok' none
st "unmet sent back" '- X : unmet : broken' deny
st "partially met sent back" '- X : partially met : half' deny
st "not met with dash separator sent back" '- X - not met - failed' deny
st "bold not met sent back" '- X : **not met** : failed' deny
st "status followed by paren (not met)" '- X : not met (flaky)' deny
st "status followed by paren (met)" '- X : met (all green)' none
st "table row met allowed" '| X | met | ok |' none
st "table row not met sent back" '| X | not met | fail |' deny
st "em dash separators met" '- X — met — fine' none
st "fallback whole-word: not met sent back" '- X was not met' deny
st "fallback whole-word: met allowed" '- X was met' none
st "check mark line met" '✓ X : met : ok' none
st "cross mark line unmet" '✗ X : unmet : no' deny
st "template line met | not met ignored" '- X : met | not met : e' none
st "numbered criterion not met sent back" '1. X : not met : e' deny
st "no criterion lines: plain not met line evaluated" 'X : not met : e' deny

# --- section boundaries (item 3) ---
expect "prose with 'not met' after bold label ignored" "$hb" "$(pre $'Acceptance check\n- a : met : e\n\n**Files changed**\nThe requirement was not met earlier but is now.\n\nContext docs: none' "sb1-$run")" none
expect "prose after Open questions label ignored" "$hb" "$(pre $'**Acceptance check**\n- a : met : e\n**Open questions:**\nStill not met in staging\nContext docs: none' "sb2-$run")" none
expect "prose after heading ignored" "$hb" "$(pre $'Acceptance check\n- a : met : e\n## Notes\n- b : not met : x\nContext docs: none' "sb3-$run")" none
expect "non-criterion prose inside section ignored when bullets exist" "$hb" "$(pre $'Acceptance check\nIt was not met at first.\n- a : met : e\nContext docs: none' "sb4-$run")" none
expect "section ends at Context docs line" "$hb" "$(pre $'Acceptance check\n- a : met : e\nContext docs: none, requirement not met elsewhere' "sb5-$run")" none

# --- missing/null/non-string text (item 6) ---
sid="nostr-$run"
for body in '{}' '{"message":null}' '{"message":5}' '{"message":["x"]}'; do
  call "$hb" "$(jq -n --argjson ti "$body" --arg id "$sid" --arg s "$scratch" '{hook_event_name:"PreToolUse",agent_id:$id,agent_type:"executor",scratchpad_dir:$s,tool_input:$ti}')"
  [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "PreToolUse message $body allowed" || bad "message $body" "$out"
done
call "$hb" "$(jq -n --arg id "$sid" --arg s "$scratch" '{hook_event_name:"SubagentStop",agent_id:$id,agent_type:"executor",scratchpad_dir:$s,last_assistant_message:null}')"
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "SubagentStop null last_assistant_message allowed" || bad "null last msg"
call "$hb" "$(jq -n --arg id "$sid" --arg s "$scratch" '{hook_event_name:"SubagentStop",agent_id:$id,agent_type:"executor",scratchpad_dir:$s}')"
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "SubagentStop missing last_assistant_message allowed" || bad "missing last msg"
[ ! -e "$scratch/handback-$sid.state" ] && ok "non-string messages not counted as send-backs" || bad "state written for non-string"

# --- robustness (item 7) ---
out="$(pre "$badmsg" "nohome-$run" | jq 'del(.scratchpad_dir)' | env -u HOME -u XDG_CACHE_HOME bash "$hb" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "HOME unset and no scratchpad_dir: allowed silently" || bad "HOME unset" "rc=$rc $out"
ro="$HOME/ro"; mkdir -p "$ro"; chmod 500 "$ro"
out="$(pre "$badmsg" "ro-$run" | jq --arg d "$ro/sub" '.scratchpad_dir=$d' | XDG_CACHE_HOME="$ro/cache" bash "$hb" 2>&1 >/dev/null)"
[ -z "$out" ] && ok "unwritable state dir prints nothing to stderr" || bad "unwritable stderr" "$out"
chmod 700 "$ro"
longid="$(head -c 400 /dev/zero | tr '\0' 'a')$run"
out="$(pre "$badmsg" "$longid" | bash "$hb" 2>&1 >/dev/null)"; [ -z "$out" ] && ok "over-long agent_id no stderr" || bad "long id" "$out"
ls "$scratch" | awk '/^handback-a+/ && length($0) > 130 {f=1} END{exit f}' && ok "sanitised id length capped" || bad "id length"

# --- state lifecycle (item 8) ---
id="life-$run"
expect "lifecycle: good handback passes" "$hb" "$(pre "$good" "$id")" none
expect "lifecycle: SubagentStop after pass allowed" "$hb" "$(stp "$badmsg" "$id")" none
[ ! -e "$scratch/handback-$id.state" ] && ok "lifecycle: SubagentStop cleared state" || bad "state not cleared"
expect "lifecycle: resumed agent bad handback sent back again" "$hb" "$(pre "$badmsg" "$id")" deny
expect "lifecycle: resumed agent second bad sent back" "$hb" "$(pre "$badmsg" "$id")" deny
expect "lifecycle: resumed agent third allowed by cap" "$hb" "$(pre "$badmsg" "$id")" none
expect "lifecycle: SubagentStop after cap does not re-block" "$hb" "$(stp "$badmsg" "$id")" none
id="life2-$run"
expect "lifecycle: pass then fresh count on next handback (1)" "$hb" "$(pre "$good" "$id")" none
expect "lifecycle: bad handback after pass starts fresh (deny)" "$hb" "$(pre "$badmsg" "$id")" deny
[ "$(cat "$scratch/handback-$id.state")" = 1 ] && ok "lifecycle: fresh count is 1" || bad "fresh count"

# --- criteria prefixes and success criteria (item 5) ---
expect "'- Done when tests pass' allowed" "$req" "$(ag $'Do it\n- Done when tests pass' executor)" none
expect "'2. Acceptance criteria' allowed" "$req" "$(ag $'Do it\n2. Acceptance criteria' executor)" none
expect "'Success criteria:' allowed" "$req" "$(ag $'Do it\nSuccess criteria:\n- x' executor)" none
expect "'## Success criteria' allowed" "$req" "$(ag $'Do it\n## Success criteria' executor)" none
expect "'success criteria' mid-sentence denied" "$req" "$(ag 'please define success criteria later' executor)" deny

# --- report size cap ---
unset CLAUDE_HANDBACK_MAX_CHARS
filler() { head -c "$1" /dev/zero | tr '\0' 'y'; }
longgood="$good"$'\n'"$(filler 4100)"
expect "over-limit report from gated type sent back" "$hb" "$(pre "$longgood" "sz1-$run")" deny
r="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")"
grep -q 'limit is 4000' <<<"$r" && grep -q 'path' <<<"$r" && grep -q 'file' <<<"$r" && ok "size reason names the limit and a file path" || bad "size reason" "$r"
expect "over-limit report from exempt type sent back" "$hb" "$(pre "$(filler 4100)" "sz2-$run" Explore)" deny
expect "under-limit report from exempt type allowed" "$hb" "$(pre "$(filler 3900)" "sz3-$run" Explore)" none
expect "under-limit good report unaffected" "$hb" "$(pre "$good$(filler 3000)" "sz4-$run")" none
expect "code blocks count toward the limit" "$hb" "$(pre "$good"$'\n```\n'"$(filler 4100)"$'\n```' "sz5-$run")" deny
expect "SubagentStop over-limit exempt blocked" "$hb" "$(stp "$(filler 4100)" "sz6-$run" false Plan)" block
expect "exactly at the limit allowed" "$hb" "$(pre "$(filler 4000)" "sz7-$run" Explore)" none
expect "one over the limit sent back" "$hb" "$(pre "$(filler 4001)" "sz8-$run" Explore)" deny
CLAUDE_HANDBACK_MAX_CHARS=100 call "$hb" "$(pre "$(filler 150)" "sz9-$run" Explore)"
jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null 2>&1 && grep -q 'limit is 100' <<<"$out" && ok "env override lowers the limit" || bad "env override low" "$out"
CLAUDE_HANDBACK_MAX_CHARS=9000 call "$hb" "$(pre "$(filler 5000)" "sz10-$run" Explore)"
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "env override raises the limit" || bad "env override high" "$out"
for badv in abc 0 -5 1.5 ''; do
  CLAUDE_HANDBACK_MAX_CHARS="$badv" call "$hb" "$(pre "$(filler 4100)" "szb-${badv:-empty}-$run" Explore)"
  jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null 2>&1 && grep -q 'limit is 4000' <<<"$out" && ok "bad CLAUDE_HANDBACK_MAX_CHARS '$badv' uses default" || bad "bad env '$badv'" "$out"
done
grep -q '4235 characters' <<<"$(CLAUDE_HANDBACK_MAX_CHARS= call "$hb" "$(pre "$longgood" "szlen-$run")"; echo "$out")" && ok "reason contains the actual length" || bad "reason length"
call "$hb" "$(pre "$(filler 4100)" "szlen2-$run" Explore)"; grep -q 'is 4100 characters' <<<"$out" && grep -q 'exactly 4000 is fine' <<<"$out" && grep -q 'If you can write files' <<<"$out" && ok "reason has length, boundary and optional file hint" || bad "reason wording" "$out"
emoji="$(jq -rn '[range(4000)|"😀"]|join("")')"
LC_ALL=C call "$hb" "$(pre "$emoji" "szemo-$run" Explore)"; [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "4000 emoji pass under LC_ALL=C (chars, not bytes)" || bad "emoji bytes counted" "$out"
LC_ALL=C call "$hb" "$(pre "${emoji}😀" "szemo2-$run" Explore)"; grep -q 'is 4001 characters' <<<"$out" && ok "4001 emoji sent back with char count" || bad "emoji over" "$out"
CLAUDE_HANDBACK_MAX_CHARS=08 call "$hb" "$(pre "$(filler 9)" "sz08-$run" Explore)"; grep -q 'limit is 8 ' <<<"$out" && ok "override 08 is decimal 8" || bad "override 08" "$out"
CLAUDE_HANDBACK_MAX_CHARS=09 call "$hb" "$(pre "$(filler 9)" "sz09-$run" Explore)"; [ -z "$out" ] && ok "override 09 is decimal 9 (9 chars pass)" || bad "override 09" "$out"
CLAUDE_HANDBACK_MAX_CHARS=09 call "$hb" "$(pre "$(filler 10)" "sz09b-$run" Explore)"; grep -q 'limit is 9 ' <<<"$out" && ok "override 09 limits at 9" || bad "override 09b" "$out"
expect "combined: long and no Acceptance check" "$hb" "$(pre "$(filler 4100)"$'\nContext docs: none' "sz11-$run")" deny
r="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")"
grep -q 'limit is 4000' <<<"$r" && grep -q 'Acceptance check' <<<"$r" && ok "combined reason has size and acceptance problems" || bad "combined size reason" "$r"
id="szcap-$run"; lm="$(filler 4100)"
expect "size attempt 1 sent back" "$hb" "$(pre "$lm" "$id" Explore)" deny
expect "size attempt 2 sent back" "$hb" "$(pre "$lm" "$id" Explore)" deny
expect "size attempt 3 passes by the cap" "$hb" "$(pre "$lm" "$id" Explore)" none
CLAUDE_ACCEPTANCE_GATE=off call "$hb" "$(pre "$lm" "szoff-$run" Explore)"; [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "off switch disables the size check" || bad "off switch size" "$out"
CLAUDE_ACCEPTANCE_GATE=off call "$hb" "$(pre "$longgood" "szoff2-$run")"; [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "off switch disables size check for gated type" || bad "off switch size gated" "$out"

# --- fail open: malformed and empty stdin, every script ---
for s in "$start" "$req" "$hb"; do
  n="$(basename "$s")"
  for in in '' 'not json {' '[]' '"str"' '{}'; do
    call "$s" "$in"; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "$n silent on stdin: ${in:-<empty>}" || bad "$n on stdin '$in'" "rc=$rc out=$out"
  done
  # shared file missing -> built-in fallback, still safe
  iso="$(mktemp -d)"; cp "$s" "$iso/"; call "$iso/$n" 'garbage'; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "$n safe without shared file" || bad "$n without shared file"
done
iso="$(mktemp -d)"; cp "$req" "$iso/"; call "$iso/require-acceptance-criteria.sh" "$(ag 'x' executor)"
jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null 2>&1 && ok "require gate still denies without shared file" || bad "require fallback deny"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
