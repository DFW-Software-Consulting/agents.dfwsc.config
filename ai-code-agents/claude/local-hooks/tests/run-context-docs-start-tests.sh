#!/usr/bin/env bash
# Payload-driven tests for the "Tool card" that context-docs-start.sh appends on
# SubagentStart. Temporary HOME and repos; never touches live ~/.claude files.
# fixtures/context-docs-start-*.orig.json are the raw outputs of the hook as it
# was before the card existed (origin/main), for the unchanged-output pin.
# Test seams (default to the real files): CONTEXT_DOCS_START_HOOK points at
# another copy of the hook, CONTEXT_DOCS_START_AGENTS at another agents folder.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
agents="${CONTEXT_DOCS_START_AGENTS:-$hooks/../agents}"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
unset CLAUDE_ACCEPTANCE_GATE
start="${CONTEXT_DOCS_START_HOOK:-$hooks/context-docs-start.sh}"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1 ${2:-}"; }

opted="$HOME/opted"; plain="$HOME/plain"
mkdir -p "$opted/docs/context" "$plain"; git -C "$opted" init -q
printf -- '- [auth.md](auth.md) : read when changing auth\n' >"$opted/docs/context/INDEX.md"

sa() { jq -n --arg c "$1" --arg t "$2" '{hook_event_name:"SubagentStart",cwd:$c,agent_id:"x",agent_type:$t}'; }
call() { out="$(printf '%s' "$2" | bash "$1" 2>&1)"; rc=$?; }
ctx_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out"; }
# card_of: the card text (from "Tool card:" on), or empty
card_of() { ctx_of | awk '/^Tool card:$/{f=1} f'; }
restricted_has() { grep -q 'Monitor, ToolSearch and TaskStop are not available' <<<"$1"; }
general_has() { grep -q '^- Monitor exists\.' <<<"$1"; }

# 1. restricted card
for t in executor check git-workflow; do
  call "$start" "$(sa "$plain" "$t")"; c="$(card_of)"
  if [ "$rc" -eq 0 ] && [ -n "$c" ] && restricted_has "$c" && ! general_has "$c"; then ok "$t: restricted card"; else bad "$t: restricted card" "rc=$rc out=$out"; fi
done
# 2. general-purpose card
call "$start" "$(sa "$plain" general-purpose)"; c="$(card_of)"
if [ "$rc" -eq 0 ] && general_has "$c" && ! restricted_has "$c"; then ok "general-purpose: Monitor card, not restricted wording"; else bad "general-purpose card" "rc=$rc out=$out"; fi
# 3. no card
for t in Explore orchestrator fork unknown-type vercel:x claude Plan antipattern-sniffer ""; do
  call "$start" "$(sa "$opted" "$t")"
  if [ "$rc" -eq 0 ] && ! grep -q 'Tool card' <<<"$out"; then ok "no card for type '${t:-<empty>}'"; else bad "no card for type '${t:-<empty>}'" "rc=$rc out=$out"; fi
done
call "$start" "$(jq -n --arg c "$plain" '{hook_event_name:"SubagentStart",cwd:$c,agent_id:"x"}')"
if [ "$rc" -eq 0 ] && ! grep -q 'Tool card' <<<"$out"; then ok "no card for missing agent_type"; else bad "missing agent_type" "$out"; fi
# 4. SessionStart
call "$start" "$(jq -n --arg c "$opted" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
if [ "$rc" -eq 0 ] && ! grep -q 'Tool card' <<<"$out"; then ok "SessionStart: no card"; else bad "SessionStart" "$out"; fi
call "$start" "$(jq -n --arg c "$opted" '{hook_event_name:"SessionStart",cwd:$c,agent_type:"executor"}')"
if [ "$rc" -eq 0 ] && ! grep -q 'Tool card' <<<"$out"; then ok "SessionStart with agent_type executor: no card"; else bad "SessionStart executor" "$out"; fi

# 5. unchanged-output pin: new output minus the card equals the pre-card hook output, exactly
for t in executor Explore; do
  call "$start" "$(sa "$opted" "$t")"; c="$(ctx_of)"; card="$(card_of)"
  if [ -n "$card" ]; then base="${c%$'\n\n'"$card"}"; else base="$c"; fi
  rebuilt="$(jq -n --arg e SubagentStart --arg c "$base" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}')"
  want="$(cat "$here/fixtures/context-docs-start-$t.orig.json")"
  if [ "$rebuilt" = "$want" ]; then ok "$t: output minus card equals pre-card output"; else bad "$t: output pin" "got: $rebuilt"; fi
done
# a card is only ever appended: executor output starts with the pre-card text
call "$start" "$(sa "$opted" executor)"; c="$(ctx_of)"; pre="$(jq -r .hookSpecificOutput.additionalContext "$here/fixtures/context-docs-start-executor.orig.json")"
[ "${c:0:${#pre}}" = "$pre" ] && ok "executor: card appended after the old text" || bad "executor: card is a suffix"

# 6. malformed and non-object input: silent, exit 0
for p in '{bad' '' '[]' '"x"' '42' 'null'; do
  call "$start" "$p"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "input '$p': silent exit 0"; else bad "input '$p'" "rc=$rc out=$out"; fi
done

# 7. acceptance switch off, and fallback without _handback-common.sh
for t in executor check general-purpose; do
  CLAUDE_ACCEPTANCE_GATE=off call "$start" "$(sa "$plain" "$t")"; c="$(ctx_of)"
  if [ "$rc" -eq 0 ] && [ -n "$(card_of)" ] && { [ "$t" = check ] || grep -q 'Context docs:' <<<"$c"; } && ! grep -q 'Acceptance check' <<<"$c"; then ok "gate off, $t: card present, acceptance text absent"; else bad "gate off $t" "$out"; fi
done
iso="$(mktemp -d)"; cp "$start" "$iso/context-docs-start.sh"
for t in executor check general-purpose Explore; do
  call "$iso/context-docs-start.sh" "$(sa "$plain" "$t")"; c="$(card_of)"
  case "$t" in
    Explore) [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "fallback: Explore silent" || bad "fallback Explore" "$out" ;;
    general-purpose) [ "$rc" -eq 0 ] && general_has "$c" && ok "fallback: general-purpose card" || bad "fallback general-purpose" "$out" ;;
    *) [ "$rc" -eq 0 ] && restricted_has "$c" && ok "fallback: $t card" || bad "fallback $t" "$out" ;;
  esac
done
rm -rf "$iso"

# 8. size: 6 lines or fewer including the heading
for t in executor general-purpose; do
  call "$start" "$(sa "$plain" "$t")"; n="$(card_of | wc -l)"
  [ "$n" -ge 3 ] && [ "$n" -le 6 ] && ok "$t card is $n lines (<= 6)" || bad "$t card size" "$n lines"
done

# 8b. commit line: -m per paragraph is recommended; a stdin message file or heredoc is not
for t in executor general-purpose; do
  call "$start" "$(sa "$plain" "$t")"; c="$(card_of)"
  if grep -qF 'git commit -m "subject" -m "paragraph", one -m per paragraph' <<<"$c"; then ok "$t card: commit line recommends -m per paragraph"; else bad "$t card: commit line" "$c"; fi
  if ! grep -qE 'Commit with git commit -F|only cd, git add' <<<"$c"; then ok "$t card: does not recommend a heredoc commit"; else bad "$t card recommends a heredoc commit" "$c"; fi
done

# 9. drift guard against the agents' tools: lines
allow="$(grep -m1 -E '^[[:space:]]+[a-z-]+(\|[a-z-]+)+\)[[:space:]]*$' "$start" | sed -E 's/\)[[:space:]]*$//; s/^[[:space:]]+//' | tr '|' ' ')"
n_allow="$(wc -w <<<"$allow")"
if [ "$n_allow" -ge 1 ]; then ok "drift: parsed $n_allow allow-listed names from the hook"; else bad "drift: could not parse the allow-list from the hook case line"; fi
if [ ! -d "$agents" ]; then
  bad "drift: agents folder is not a directory" "$agents"
else
  examined=0
  for f in "$agents"/*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"
    tools="$(grep -m1 '^tools:' "$f" || true)"
    [ -n "$tools" ] || continue
    examined=$((examined + 1))
    if grep -qw 'Monitor' <<<"$tools"; then bad "drift: $name lists Monitor in tools:" "the card wording must be revisited"; continue; fi
    call "$start" "$(sa "$plain" "$name")"; c="$(card_of)"
    if grep -qw 'Bash' <<<"$tools"; then
      restricted_has "$c" && ok "drift: $name (Bash) has the restricted card" || bad "drift: $name has Bash but no restricted card" "update the allow-list in context-docs-start.sh"
    else
      [ -z "$c" ] && ok "drift: $name (no Bash) has no card" || bad "drift: $name has no Bash but got a card" "update the allow-list in context-docs-start.sh"
    fi
  done
  if [ "$examined" -ge "$n_allow" ]; then ok "drift: examined $examined tools: lines (>= $n_allow allow-listed)"; else bad "drift: examined only $examined tools: lines, fewer than the $n_allow allow-listed types"; fi
  for name in $allow; do
    tl="$(grep -m1 '^tools:' "$agents/$name.md" 2>/dev/null || true)"
    if grep -qw 'Bash' <<<"$tl"; then ok "drift: allow-listed $name has an agent file with Bash"; else bad "drift: allow-listed $name has no agent file with Bash in tools:" "remove it from the hook's allow-list or add the agent"; fi
  done
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
