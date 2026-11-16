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
