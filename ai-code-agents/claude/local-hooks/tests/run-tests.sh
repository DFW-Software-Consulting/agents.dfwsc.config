#!/usr/bin/env bash
# Payload-driven tests for the delegation gate scripts and no-agent-mention.py.
# Runs against the scripts in this repo, never the live copies. Uses a temporary
# HOME so the real ~/.claude/delegate-gate.off is never read or touched.
# Usage: local-hooks/tests/run-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
pyhook="$(cd "$hooks/../hooks" && pwd)/no-agent-mention.py"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_DELEGATE_GATE CLAUDE_DELEGATE_GATE_OFF_FILE
off="$HOME/.claude/delegate-gate.off"
scratch="$HOME/scratch"; mkdir -p "$scratch"

pass=0; fail=0
# check NAME EXPECT(deny|allow) SCRIPT-CMD PAYLOAD
check() {
  local name="$1" expect="$2" script="$3" payload="$4" out rc got
  out="$(printf '%s' "$payload" | $script 2>&1)"; rc=$?
  if grep -q '"permissionDecision": *"deny"' <<<"$out"; then got=deny; else got=allow; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); echo "ok   - $name"
  else
    fail=$((fail + 1)); echo "FAIL - $name (expected $expect, got $got, rc=$rc)"; echo "       output: $out"
  fi
}
gate="bash $hooks/delegate-gate.sh"
model="bash $hooks/require-agent-model.sh"
remind="bash $hooks/delegate-reminder.sh"
mention="python3 $pyhook"

bash_payload() { jq -n --arg c "$1" --arg s "$scratch" '{tool_name:"Bash",scratchpad_dir:$s,tool_input:{command:$c}}'; }
sub_bash_payload() { jq -n --arg c "$1" '{tool_name:"Bash",agent_id:"a1",tool_input:{command:$c}}'; }
edit='{"tool_name":"Edit","tool_input":{"file_path":"/repo/src/x.ts"}}'
agent_nomodel='{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"x"}}'

# --- Edit/Write behaviour (unchanged) ---
check "Edit in main session denied" deny "$gate" "$edit"
check "Edit in subagent allowed" allow "$gate" '{"agent_id":"a1","tool_name":"Edit","tool_input":{"file_path":"/repo/src/x.ts"}}'
check "Edit into allowlisted .claude path allowed" allow "$gate" "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$HOME/.claude/CLAUDE.md\"}}"

# --- Bash gate ---
check "Bash ls allowed" allow "$gate" "$(bash_payload 'ls -la')"
check "jq with > in quotes allowed" allow "$gate" "$(bash_payload "jq '.a > 1' f.json")"
check "awk with > in quotes allowed" allow "$gate" "$(bash_payload "awk '\$1 > 5' f.txt")"
check "grep with > in double quotes allowed" allow "$gate" "$(bash_payload 'grep "a > b" f.txt')"
check "redirect to /dev/null with 2>&1 allowed" allow "$gate" "$(bash_payload 'cmd > /dev/null 2>&1')"
check "2>/dev/null allowed" allow "$gate" "$(bash_payload 'cmd 2>/dev/null')"
check ">&2 allowed" allow "$gate" "$(bash_payload 'echo hi >&2')"
check "/dev/stdout allowed" allow "$gate" "$(bash_payload 'echo hi > /dev/stdout')"
check "echo hi > somefile denied" deny "$gate" "$(bash_payload 'echo hi > somefile')"
check "append >> denied" deny "$gate" "$(bash_payload 'echo hi >> notes.txt')"
check "&> denied" deny "$gate" "$(bash_payload 'make &> build.log')"
check "2> file denied" deny "$gate" "$(bash_payload 'make 2> err.log')"
check "tee to file denied" deny "$gate" "$(bash_payload 'echo hi | tee out.txt')"
check "sed -i denied" deny "$gate" "$(bash_payload "sed -i 's/a/b/' f.txt")"
check "perl -pi -e denied" deny "$gate" "$(bash_payload "perl -pi -e 's/a/b/' f.txt")"
check "awk -i inplace denied" deny "$gate" "$(bash_payload "awk -i inplace '{print}' f.txt")"
check "sed without -i allowed" allow "$gate" "$(bash_payload "sed -n 's/a/b/p' f.txt")"
check "redirect into scratchpad allowed" allow "$gate" "$(bash_payload "echo hi > $scratch/out.txt")"
check "redirect into ~/.claude allowed" allow "$gate" "$(bash_payload "echo hi > $HOME/.claude/notes.md")"
check "tee into allowlisted dir allowed" allow "$gate" "$(bash_payload "echo hi | tee $HOME/.claude/x.md")"
check "sed -i on allowlisted file allowed" allow "$gate" "$(bash_payload "sed -i 's/a/b/' $HOME/.claude/x.md")"
check "heredoc-fed script containing > allowed" allow "$gate" "$(bash_payload $'python3 - <<\'EOF\'\nx = 1\nif x > 0:\n    print(x)\nEOF')"
check "redirect after heredoc terminator still denied" deny "$gate" "$(bash_payload $'cat <<EOF > out.txt\nhello\nEOF')"
check "unparseable command allowed" allow "$gate" "$(bash_payload "echo 'unterminated > f")"
check "Bash write in subagent allowed" allow "$gate" "$(sub_bash_payload 'echo hi > somefile')"
if bash "$hooks/delegate-gate.sh" <<<"$(bash_payload 'echo hi > somefile')" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("subagent") and test("delegate-gate.off")' >/dev/null; then
  pass=$((pass + 1)); echo "ok   - Bash denial message names subagent and escape hatch"
else fail=$((fail + 1)); echo "FAIL - Bash denial message"; fi

# --- scanner regressions (mid-word quotes, arithmetic, escapes, comments) ---
for c in "git log --format='%h => %s'" 'git log --pretty="format:%h > %s" | head' 'git commit -m"a > b"' \
  'echo $((3>2))' 'echo $(( 1 > 0 ))' '(( x > y )) && echo y' 'echo a \> b' 'echo hi # > x' \
  "jq --arg q 'a>b' -n '\$q'" 'gh pr list --search "created:>2026-01-01"' \
  "gh pr view 1 --jq '.[] | select(.n > 3)'" 'psql -c "select 1 where 2 > 1"' \
  '[[ $x > $y ]] && echo y' '[[ a > b ]] && echo y' 'echo x >&-' 'echo x 2>&1 | cat'; do
  check "allow: $c" allow "$gate" "$(bash_payload "$c")"
done
check "Bash payload with empty command allowed" allow "$gate" '{"tool_name":"Bash","tool_input":{"command":""}}'
check "Bash payload with no command allowed" allow "$gate" '{"tool_name":"Bash","tool_input":{}}'
for c in 'X=1 tee f' 'echo x >out.txt' 'echo x >"my file.txt"' 'echo x 1>out.txt' 'make &>> build.log' \
  'ls && echo x > out.txt' 'echo "a > b" > out.txt' 'FOO=a BAR=b sed -i s/a/b/ f' 'echo $(echo x > out.txt)' 'echo x >| out.txt'; do
  check "deny: $c" deny "$gate" "$(bash_payload "$c")"
done
touch -d '+2 hours' "$off"
check "future-mtime off-file means gate ON" deny "$gate" "$edit"
rm -f "$off"

# --- keywords, ${...}, normalisation, env/find/backtick/$'' ---
for c in 'if [[ $a > b ]]; then echo; fi' 'while [[ $i > 0 ]]; do break; done' 'echo ${x:->}' 'echo ${x:-a>b}' \
  'echo ${x//a/>}' 'echo ${x/>/b}' 'echo ${x:-"a}b>"}' "echo $HOME/.claude/x > $HOME/.claude/y"; do
  check "allow: $c" allow "$gate" "$(bash_payload "$c")"
done
for c in 'if true; then echo x > f; fi' 'echo ${x} > f' "echo x > $HOME/.claude/../f" 'echo x > ~/.claude/../f' \
  'env X=1 tee f' 'find . -exec sed -i s/a/b/ {} +' 'echo `date > f`' "echo \$'it\\'s' > f"; do
  check "deny: $c" deny "$gate" "$(bash_payload "$c")"
done
check "allow: echo \$'a>b'" allow "$gate" "$(bash_payload "echo \$'a>b'")"
check "allow: backtick without write" allow "$gate" "$(bash_payload 'echo `date`')"

# --- Escape hatch: off-file TTL and env ---
touch "$off"
check "fresh off-file disables gate" allow "$gate" "$edit"
check "fresh off-file disables Bash gate" allow "$gate" "$(bash_payload 'echo hi > somefile')"
check "fresh off-file disables require-agent-model" allow "$model" "$agent_nomodel"
out="$(echo '{}' | $remind)"; if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - fresh off-file silences reminder"; else fail=$((fail + 1)); echo "FAIL - reminder not silenced: $out"; fi
touch -d '13 hours ago' "$off"
check "13h-old off-file does not disable gate" deny "$gate" "$edit"
check "13h-old off-file does not disable require-agent-model" deny "$model" "$agent_nomodel"
out="$(echo '{}' | $remind)"; if grep -q 'Delegation mode' <<<"$out"; then pass=$((pass + 1)); echo "ok   - 13h-old off-file: reminder still emitted"; else fail=$((fail + 1)); echo "FAIL - reminder missing: $out"; fi
if printf '%s' "$edit" | $gate | grep -q 'expired' && echo '{}' | $remind | grep -q 'expired' && printf '%s' "$agent_nomodel" | $model | grep -q 'expired'; then
  pass=$((pass + 1)); echo "ok   - expiry note shown in all three"; else fail=$((fail + 1)); echo "FAIL - expiry note missing"; fi
[ -e "$off" ] && { pass=$((pass + 1)); echo "ok   - stale off-file not deleted"; } || { fail=$((fail + 1)); echo "FAIL - stale off-file deleted"; }
rm -f "$off"
export CLAUDE_DELEGATE_GATE=off
check "env off disables gate" allow "$gate" "$edit"
check "env off disables require-agent-model" allow "$model" "$agent_nomodel"
out="$(echo '{}' | $remind)"; if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - env off silences reminder"; else fail=$((fail + 1)); echo "FAIL - env off reminder: $out"; fi
unset CLAUDE_DELEGATE_GATE
export CLAUDE_DELEGATE_GATE_OFF_FILE="$HOME/custom.off"; touch "$CLAUDE_DELEGATE_GATE_OFF_FILE"
check "off-file path override honoured" allow "$gate" "$edit"
unset CLAUDE_DELEGATE_GATE_OFF_FILE
# shared file missing -> gate ON
iso="$(mktemp -d)"; cp "$hooks/delegate-gate.sh" "$iso/"; touch "$off"
check "missing shared file behaves as gate ON" deny "bash $iso/delegate-gate.sh" "$edit"
rm -f "$off"
# off-file must be a regular file, or a link to one, judged by the target
unset CLAUDE_DELEGATE_GATE
od="$(mktemp -d)"; export CLAUDE_DELEGATE_GATE_OFF_FILE="$od/the.off"
mkdir "$od/the.off"
check "fresh directory at the off-file path is not an off-file" deny "$gate" "$edit"
rm -rf "$od/the.off"; touch -d '13 hours ago' "$od/old"; touch "$od/new"
ln -s "$od/old" "$od/the.off"; touch -h "$od/the.off"
check "fresh link to a stale file is stale (gate ON)" deny "$gate" "$edit"
rm -f "$od/the.off"; ln -s "$od/new" "$od/the.off"; touch -h -d '13 hours ago' "$od/the.off"
check "stale link to a fresh file is fresh (gate off)" allow "$gate" "$edit"
rm -f "$od/the.off"; mkdir "$od/d"; ln -s "$od/d" "$od/the.off"
check "link to a directory is not an off-file" deny "$gate" "$edit"
rm -f "$od/the.off"; ln -s "$od/missing" "$od/the.off"
check "dangling link is not an off-file" deny "$gate" "$edit"
unset CLAUDE_DELEGATE_GATE_OFF_FILE; rm -rf "$od"

# --- no-agent-mention.py ---
pr() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
check "commit clean allowed" allow "$mention" "$(pr 'git commit -m "fix parser"')"
check "commit with Co-Authored-By Claude denied" deny "$mention" "$(pr 'git commit -m "fix

Co-Authored-By: Claude <x@y.z>"')"
check "commit mentioning .claude path allowed" allow "$mention" "$(pr 'git commit -m "update .claude/settings"')"
check "gh pr create clean body allowed" allow "$mention" "$(pr 'gh pr create --title "Fix parser" --body "Fixes the parser"')"
check "gh pr create banned body denied" deny "$mention" "$(pr 'gh pr create --title "Fix" --body "Generated with Claude Code"')"
check "gh pr create banned title (-t) denied" deny "$mention" "$(pr 'gh pr create -t "Written by Claude" -b "ok"')"
check "gh pr edit banned --body= denied" deny "$mention" "$(pr 'gh pr edit 5 --body="Co-Authored-By: Claude <a@b.c>"')"
check "gh pr comment banned body denied" deny "$mention" "$(pr 'gh pr comment 5 -b "made with Claude Code"')"
printf 'summary\n\nGenerated with Claude Code\n' > "$HOME/body-bad.md"
printf 'summary only\n' > "$HOME/body-ok.md"
check "gh pr create banned --body-file denied" deny "$mention" "$(pr "gh pr create --title t --body-file $HOME/body-bad.md")"
check "gh pr create clean -F allowed" allow "$mention" "$(pr "gh pr create --title t -F $HOME/body-ok.md")"
check "gh pr create unreadable body-file allowed" allow "$mention" "$(pr 'gh pr create --title t --body-file /nonexistent/x.md')"
check "gh pr view with unrelated text allowed" allow "$mention" "$(pr 'gh pr view 5 --json title')"
check "gh pr create body with repo path ai-code-agents/claude/hooks allowed" allow "$mention" "$(pr 'gh pr create --title t --body "touches ai-code-agents/claude/hooks and ~/.claude/hooks"')"
check "gh pr create body with claude-code path denied (existing matcher)" deny "$mention" "$(pr 'gh pr create --title t --body "see plugins/claude-code/x"')"
check "commit then gh pr in one command: banned PR body denied" deny "$mention" "$(pr 'git commit -m ok && gh pr create --title t --body "Generated with Claude"')"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
