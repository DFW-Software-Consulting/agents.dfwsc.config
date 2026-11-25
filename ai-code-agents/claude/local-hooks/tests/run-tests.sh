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

# --- delegate-gate: targets held in variables and writes inside command bodies ---
# A target that cannot be resolved stays ALLOWED (a temporary file through a variable is everyday).
for c in 'F=/abs/file && echo hi > "$F"' 'F=/abs/file; echo hi > "$F"' 'F=/abs/file; echo hi >> $F' 'OUT=/abs/out; echo hi | tee "$OUT"' \
  'F=/abs/file; sed -i s/a/b/ "$F"' 'F=/abs/file; cp x "$F"; echo y > "$F"' 'D=/abs/dir; echo hi > "$D/x.txt"' 'F=rel.txt; echo hi > "$F"' \
  "bash -c 'echo hi > /abs/file'" "sh -c 'echo hi | tee /abs/file'" 'bash -c "echo hi > /abs/file"' "eval 'echo hi > /abs/file'" \
  "bash -c 'F=/abs/file; echo hi > \"\$F\"'" 'F=/abs/file; eval "echo hi > \$F"' 'F=/abs/file; bash -c "echo hi > \$F"' \
  "bash -c \"bash -c 'echo hi > /abs/deep'\"" "bash -c \"bash -c \\\"sh -c 'echo hi > /abs/deeper'\\\"\"" 'env -S "sh -c \"echo hi > /abs/f\""'; do
  check "deny: $c" deny "$gate" "$(bash_payload "$c")"
done
for c in "F=$scratch/x && echo hi > \"\$F\"" "OUT=$scratch/o; echo hi | tee \"\$OUT\"" "F=$HOME/.claude/n.md; sed -i s/a/b/ \"\$F\"" \
  "D=$scratch; echo hi > \"\$D/x.txt\"" "bash -c 'echo hi > $scratch/f'" "bash -c 'F=$scratch/f; echo hi > \"\$F\"'" \
  "F=$scratch/f; eval \"echo hi > \$F\"" "eval 'echo hi > $HOME/.claude/x'" "F=/dev/null; echo hi > \$F" \
  'f=$(mktemp); echo hi > "$f"' 'f=$(mktemp); cmd | tee "$f"' 'echo hi > "$OUTFILE"' 'for f in a b; do echo hi > "$f"; done' \
  'echo hi > "$f" ; f=/abs/after' 'if true; then F=/abs/f; fi; echo hi > "$F"' 'F=/abs/f; unset F; echo hi > "$F"' \
  'cmd && F=/abs/f; echo hi > "$G"' "bash -c 'echo hi > \"\$OUT\"'" "bash -c 'f=\$(mktemp); echo hi > \"\$f\"'" \
  "bash -c 'echo \"a > b\"'" "echo 'bash -c \"echo hi > /abs/file\"'" 'echo "F=/abs/file; echo hi > $F"' "bash -c 'ls /abs'" \
  "bash -c 'echo hi > /abs/file" 'F=/abs/f; echo hi > ${F}'; do
  check "allow: $c" allow "$gate" "$(bash_payload "$c")"
done
for c in 'F=/abs/file && echo hi > "$F"' "bash -c 'echo hi > /abs/file'" 'F=/abs/f; sed -i s/a/b/ "$F"' 'F=/abs/f; eval "echo > \$F"'; do
  check "subagent allowed: $c" allow "$gate" "$(sub_bash_payload "$c")"
done
touch "$off"
check "fresh off-file disables variable-target check" allow "$gate" "$(bash_payload 'F=/abs/file; echo hi > "$F"')"
rm -f "$off"
# without the shared walker only literal targets in the line are judged, as before
iso="$(mktemp -d)"; cp "$hooks/delegate-gate.sh" "$hooks/_gate-common.sh" "$hooks/_bash-write-check.py" "$iso/"
check "no walker: variable target allowed as before" allow "bash $iso/delegate-gate.sh" "$(bash_payload 'F=/abs/file; echo hi > "$F"')"
check "no walker: body write allowed as before" allow "bash $iso/delegate-gate.sh" "$(bash_payload "bash -c 'echo hi > /abs/file'")"
check "no walker: literal target still denied" deny "bash $iso/delegate-gate.sh" "$(bash_payload 'echo hi > /abs/file')"
rm -rf "$iso"

# --- no-agent-mention.py: message files from the directory the command runs in, variables, bodies ---
prc() { jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
proj="$HOME/proj"; mkdir -p "$proj/sub" "$proj/other"
printf 'fix\n\nGenerated with Claude Code\n' > "$proj/sub/bad.txt"; printf 'fix the parser\n' > "$proj/sub/ok.txt"
printf 'fine\n' > "$proj/bad.txt"   # same name, clean, in the cwd itself: the cd must win
printf 'summary\n\nGenerated with Claude Code\n' > "$proj/sub/pbad.md"; printf 'summary only\n' > "$proj/sub/pok.md"
printf 'fine\n' > "$proj/pbad.md"
for pair in "commit|git commit -F" "pr|gh pr create --title t --body-file"; do
  k="${pair%%|*}"; v="${pair#*|}"
  bad="bad.txt"; ok="ok.txt"; [ "$k" = pr ] && { bad="pbad.md"; ok="pok.md"; }
  check "$k: literal cd, relative file with attribution denied" deny "$mention" "$(prc "cd sub && $v $bad" "$proj")"
  check "$k: literal cd, relative clean file allowed" allow "$mention" "$(prc "cd sub && $v $ok" "$proj")"
  check "$k: cd with a variable path, attribution denied" deny "$mention" "$(prc "D=sub; cd \"\$D\" && $v $bad" "$proj")"
  check "$k: cd with a variable path, clean allowed" allow "$mention" "$(prc "D=sub; cd \"\$D\" && $v $ok" "$proj")"
  check "$k: absolute cd, attribution denied" deny "$mention" "$(prc "cd $proj/sub && $v $bad" "/")"
  check "$k: inside bash -c, attribution denied" deny "$mention" "$(prc "bash -c 'cd sub && $v $bad'" "$proj")"
  check "$k: inside bash -c, clean allowed" allow "$mention" "$(prc "bash -c 'cd sub && $v $ok'" "$proj")"
  check "$k: inside eval, attribution denied" deny "$mention" "$(prc "eval 'cd sub && $v $bad'" "$proj")"
  check "$k: cd to a directory without the file unreadable" "$([ $k = commit ] && echo deny || echo allow)" "$mention" "$(prc "cd other && $v $bad" "$proj")"
done
check "commit: git -C, attribution denied" deny "$mention" "$(prc "git -C sub commit -F bad.txt" "$proj")"
check "commit: git -C, clean allowed" allow "$mention" "$(prc "git -C sub commit -F ok.txt" "$proj")"
check "commit: git -C inside a body, attribution denied" deny "$mention" "$(prc "sh -c 'git -C sub commit -F bad.txt'" "$proj")"
check "commit: env -C, attribution denied" deny "$mention" "$(prc "env -C sub git commit -F bad.txt" "$proj")"
check "commit: no cd, file in the cwd read (cwd given by the payload)" allow "$mention" "$(prc "git commit -F bad.txt" "$proj")"
check "commit: file named by --file= after cd, denied" deny "$mention" "$(prc "cd sub && git commit --file=bad.txt" "$proj")"
check "pr: gh body file with -F attached after cd denied" deny "$mention" "$(prc "cd sub && gh pr create --title t -Fpbad.md" "$proj")"
check "commit: unreadable file denied" deny "$mention" "$(prc "git commit -F /nonexistent/msg.txt" "$proj")"
check "commit: unreadable relative file after cd denied" deny "$mention" "$(prc "cd sub && git commit -F missing.txt" "$proj")"
check "pr: unreadable body file allowed (as before)" allow "$mention" "$(prc "cd sub && gh pr create --title t --body-file missing.md" "$proj")"
check "pr: body file - allowed" allow "$mention" "$(prc "cd sub && gh pr create --title t --body-file -" "$proj")"
check "message in a variable, attribution denied" deny "$mention" "$(pr 'M="Generated with Claude Code"; git commit -m "$M"')"
check "message in a variable with &&, attribution denied" deny "$mention" "$(pr 'M="Co-Authored-By: Claude <a@b.c>" && git commit -m "$M"')"
check "message in a variable, clean allowed" allow "$mention" "$(pr 'M="fix the parser"; git commit -m "$M"')"
check "message in a variable braces, attribution denied" deny "$mention" "$(pr 'M="made with Claude Code"; git commit -m "${M}"')"
check "pr title in a variable, attribution denied" deny "$mention" "$(pr 'T="Written by Claude"; gh pr create --title "$T" --body ok')"
check "pr body in a variable, attribution denied" deny "$mention" "$(pr 'B="Generated with Claude Code"; gh pr create --title t --body "$B"')"
check "pr body in a variable, clean allowed" allow "$mention" "$(pr 'B="all good"; gh pr create --title t --body "$B"')"
check "message in an outer variable used in a double-quoted body denied" deny "$mention" "$(pr "M='Generated with Claude Code'; bash -c \"git commit -m '\$M'\"")"
check "inline message in bash -c denied" deny "$mention" "$(pr "bash -c 'git commit -m \"Co-Authored-By: Claude <a@b.c>\"'")"
check "inline message in bash -c clean allowed" allow "$mention" "$(pr "bash -c 'git commit -m \"fix parser\"'")"
check "inline message in eval denied" deny "$mention" "$(pr "eval 'git commit -m \"Generated with Claude Code\"'")"
check "inline message in nested bodies denied" deny "$mention" "$(pr "bash -c \"sh -c 'git commit -m \\\"Generated with Claude Code\\\"'\"")"
check "pr text inside bash -c denied" deny "$mention" "$(pr "sh -c 'gh pr create --title t --body \"Generated with Claude Code\"'")"
check "variable inside a body set in the body, denied" deny "$mention" "$(pr "bash -c 'M=\"Generated with Claude Code\"; git commit -m \"\$M\"'")"
check "unresolvable message (command substitution) allowed as before" allow "$mention" "$(pr 'git commit -m "$(cat msg.txt)"')"
check "unresolvable message (environment variable) allowed as before" allow "$mention" "$(pr 'git commit -m "$MSG"')"
check "variable not certain (set in a branch) allowed as before" allow "$mention" "$(pr 'if x; then M="Generated with Claude Code"; fi; git commit -m "$M"')"
check "loop variable message allowed as before" allow "$mention" "$(pr 'for M in "Generated with Claude Code"; do git commit -m "$M"; done')"
check "text as data (echo) silent" allow "$mention" "$(pr 'echo "M=Generated with Claude Code; git commit -m \$M"')"
check "message var unrelated to the commit allowed" allow "$mention" "$(pr 'M="Generated with Claude Code"; echo $M; git commit -m fix')"
check "malformed payload allowed" allow "$mention" 'not json'
# isolated copies: without the shared walker the hook behaves as it did
iso="$(mktemp -d)"; mkdir "$iso/hooks"; cp "$(dirname "$pyhook")/no-agent-mention.py" "$iso/hooks/"
check "no walker: variable message allowed as before" allow "python3 $iso/hooks/no-agent-mention.py" "$(pr 'M="Generated with Claude Code"; git commit -m "$M"')"
check "no walker: body message allowed as before" allow "python3 $iso/hooks/no-agent-mention.py" "$(pr "bash -c 'git commit -m \"Generated with Claude Code\"'")"
check "no walker: literal message still denied" deny "python3 $iso/hooks/no-agent-mention.py" "$(pr 'git commit -m "Generated with Claude Code"')"
check "no walker: relative file read from the working directory as before" allow "python3 $iso/hooks/no-agent-mention.py" "$(prc "cd sub && gh pr create --title t --body-file pbad.md" "$proj")"
mkdir "$iso/local-hooks"; echo 'raise RuntimeError("broken")' > "$iso/local-hooks/_cmd_dirs.py"
check "broken walker: variable message allowed as before" allow "python3 $iso/hooks/no-agent-mention.py" "$(pr 'M="Generated with Claude Code"; git commit -m "$M"')"
# the repository layout, a copy of both directories side by side, and an installed layout of links
lh="$(cd "$hooks" && pwd)"; hk="$(dirname "$pyhook")"
iso2="$(mktemp -d)"; mkdir "$iso2/hooks" "$iso2/local-hooks"; cp "$hk"/no-agent-mention.py "$iso2/hooks/"; cp "$lh"/*.py "$iso2/local-hooks/"
check "copied side by side: variable message denied" deny "python3 $iso2/hooks/no-agent-mention.py" "$(pr 'M="Generated with Claude Code"; git commit -m "$M"')"
iso3="$(mktemp -d)"; ln -s "$hk" "$iso3/hooks"; ln -s "$lh" "$iso3/local-hooks"
check "linked layout: variable message denied" deny "python3 $iso3/hooks/no-agent-mention.py" "$(pr 'M="Generated with Claude Code"; git commit -m "$M"')"
iso4="$(mktemp -d)"; mkdir "$iso4/cfg"; ln -s "$lh" "$iso4/cfg/local-hooks"; mkdir "$iso4/cfg/hooks"; ln -s "$hk/no-agent-mention.py" "$iso4/cfg/hooks/no-agent-mention.py"
check "linked file beside linked local-hooks: variable message denied" deny "python3 $iso4/cfg/hooks/no-agent-mention.py" "$(pr 'M="Generated with Claude Code"; git commit -m "$M"')"
rm -rf "$iso" "$iso2" "$iso3" "$iso4"

# --- reassignment to a command's output drops the old value (stays allowed: unknown target) ---
for c in 'F=/abs/x; F=`mktemp`; echo hi > "$F"' 'F=/abs/x; F=$(mktemp); echo hi > "$F"' "F=$scratch/x; F=\`pwd\`/y; echo hi > \"\$F\"" \
  'F=/abs/x; F=$((1+2)); echo hi > "$F"' 'F=/abs/x; F=$G; echo hi > "$F"' 'F=/abs/x; F=/abs/*; echo hi > "$F"'; do
  check "allow: $c" allow "$gate" "$(bash_payload "$c")"
done
check "deny: assignment after the write does not hide it" deny "$gate" "$(bash_payload 'F=/abs/x; echo hi > "$F"; F=`mktemp`')"
for c in 'D=$(pwd)/x tee "$D" </dev/null' 'D=`pwd`/x tee "$D" </dev/null' 'env D=$(pwd)/x tee "$D" </dev/null' "bash -c 'D=\$(pwd)/x tee \"\$D\" </dev/null'" \
  'GIT_DIR=$(pwd)/.git git status > "$OUT"'; do
  check "allow: substitution in a prefix assignment, target unresolvable: $c" allow "$gate" "$(bash_payload "$c")"
done
# an unresolvable target is never a denial here, glued substitutions included
for c in 'echo x > $(pwd)/f' 'echo x > "$(pwd)"/f' 'echo x > pre$(pwd)post' 'echo x > `pwd`/f' 'tee $(pwd)/f </dev/null' \
  'git -C $(pwd)/a push origin main > "$OUT"' 'git -C `pwd`/a commit -m x > "$OUT"' 'git --git-dir=$(pwd)/.git status > "$OUT"' \
  "bash -c 'git -C \$(pwd)/a push origin main > \"\$OUT\"'" 'eval git -C $(pwd)/a push origin main'; do
  check "allow: unresolvable target with a glued substitution: $c" allow "$gate" "$(bash_payload "$c")"
done

# --- commit message file with the option attached (-Fmsg.txt) ---
for c in 'git commit -Fbad.txt' 'git commit -aFbad.txt' 'git commit -sF bad.txt' 'git commit -a -F bad.txt' 'git commit --file=bad.txt'; do
  check "attached -F file with attribution denied: $c" deny "$mention" "$(prc "cd sub && $c" "$proj")"
done
for c in 'git commit -Fok.txt' 'git commit -aFok.txt' 'git commit -am "fix parser"' 'git commit -mFbad.txt' 'git commit -am"fix parser"'; do
  check "clean or message form allowed: $c" allow "$mention" "$(prc "cd sub && $c" "$proj")"
done
check "attached -F unreadable file denied" deny "$mention" "$(prc "cd sub && git commit -Fmissing.txt" "$proj")"

# --- message sources: here-document on standard input, another program's -F, glued names, same-line file ---
hd() { printf "%s <<'EOF'\n%s\nEOF" "$1" "$2"; }
stubbin="$HOME/stubbin"; mkdir -p "$stubbin"; printf '#!/bin/sh\nexit 0\n' > "$stubbin/gh"; chmod +x "$stubbin/gh"
mention_gh="env PATH=$stubbin:$PATH python3 $pyhook"  # a gh on PATH, whatever the machine has
check "-F - here-document, clean body allowed" allow "$mention" "$(pr "$(hd 'git commit -F -' 'fix parser')")"
check "-F - here-document, crediting body denied" deny "$mention" "$(pr "$(hd 'git commit -F -' 'Generated with Claude Code')")"
check "--file=- here-document after git add, clean allowed" allow "$mention" "$(pr "$(hd 'git add -A && git commit --file=-' 'fix parser')")"
check "/dev/stdin here-document, crediting body denied" deny "$mention" "$(pr "$(hd 'git commit -F /dev/stdin' 'Co-Authored-By: Claude <x@y.z>')")"
check "-F - here-document plus another input denied" deny "$mention" "$(pr "$(hd 'git commit -F - < /etc/hostname' 'fix parser')")"
check "-F - here-document on fd 3 denied" deny "$mention" "$(pr $'git commit -F - 3<<\'EOF\'\nfix parser\nEOF')"
check "-F - piped and here-document denied" deny "$mention" "$(pr "$(hd 'echo x | git commit -F -' 'fix parser')")"
check "-F - unquoted here-document with a substitution denied" deny "$mention" "$(pr $'git commit -F - <<EOF\n$(cat x)\nEOF')"
check "-F - here-document with an editor run denied" deny "$mention" "$(pr "$(hd 'git -c core.editor=true commit -e -F -' 'fix parser')")"
check "-F - with no here-document denied" deny "$mention" "$(pr 'git commit -F -')"
check "gh api -F body=@missing beside a commit denied (as before)" deny "$mention_gh" "$(pr 'git commit -m "fix parser" && gh api -X PATCH repos/o/r/pulls/1 -F body=@/nonexistent/b.md')"
check "awk -F beside a commit denied (as before)" deny "$mention" "$(pr "awk -F'|' '{print \$1}' x; git commit -m 'fix parser'")"
check "-F in a here-document body denied (as before)" deny "$mention_gh" "$(pr "$(hd 'cat > notes.md' 'gh api x -F body=@b.md')
git commit -m 'fix parser'")"
check "-F after a prose word (not a program on PATH) denied" deny "$mention_gh" "$(pr "$(hd 'cat > notes.md' 'call gh api -F body=@b.md')
git commit -m 'fix parser'")"
check "-F after a git word is still the commit's: denied" deny "$mention" "$(pr 'echo commit | xargs -I{} git {} -F /nonexistent/m.txt')"
check "-F of a function defined on the line denied" deny "$mention" "$(pr 'f() { git commit "$@"; }; f -F /nonexistent/m.txt')"
check "-F after an unknown variable denied" deny "$mention" "$(pr 'git commit -m ok && ssh h $X -F /nonexistent/m.txt')"
check "glued name in a brace group, clean file allowed" allow "$mention" "$(pr "{ git commit -F $HOME/body-ok.md; }")"
check "glued name in a substitution, crediting file denied (no longer resolved)" deny "$mention" "$(pr "echo \$(git commit -F $HOME/body-bad.md)")"
check "escaped glued name is another file: denied" deny "$mention" "$(pr "git commit -F $HOME/body-ok.md\\;")"
check "file written by cat here-document then committed, clean allowed" allow "$mention" "$(pr "$(hd 'cat > m.txt' 'fix parser')
git commit -F m.txt")"
check "file written by cat here-document then committed, crediting denied" deny "$mention" "$(pr "$(hd 'cat > m.txt' 'Generated with Claude Code')
git commit -F m.txt")"
check "file written then changed on the line denied" deny "$mention" "$(pr "$(hd 'cat > m.txt' 'fix parser')
git checkout -- m.txt; git commit -F m.txt")"
check "crediting --trailer denied" deny "$mention" "$(pr 'git commit -m "fix parser" --trailer "Co-authored-by: Claude <x@y.z>"')"
check "crediting here-document body on a commit line denied" deny "$mention" "$(pr "$(hd 'cat > notes.md' 'Generated with Claude Code')
git commit -m docs")"
# lines that may redefine what a command runs: no new rule applies
for pre in "eval 'f() { :; }'; " 'alias g=git; ' 'f() { :; }; ' 'hash -p /bin/true awk; ' '. ./defs.sh; ' 'source defs.sh; ' \
  'export PATH=/tmp/x:/usr/bin; ' 'PATH=/tmp/x:/usr/bin; ' 'command -v git; ' 'builtin true; ' 'exec 3>&-; ' 'enable -n echo; ' \
  'BASH_ENV=x; ' 'git config core.hooksPath h; ' 'GIT_EDITOR=x; '; do
  check "redefining line keeps the old reading: $pre" deny "$mention" "$(pr "${pre}$(hd 'git commit -F -' 'fix parser')")"
done
check "a function named git keeps the old reading" deny "$mention" "$(pr "git() { command git \"\$@\"; }
$(hd 'git commit -F -' 'fix parser')")"
check "a git binary that is not the git on PATH keeps the old reading" deny "$mention" "$(pr "$(hd '/tmp/nonexistent/git commit -F -' 'fix parser')")"
check "an earlier command that may write the hooks keeps the old reading" deny "$mention" "$(pr "cp x .git/ho''oks/commit-msg; $(hd 'git commit -F -' 'fix parser')")"
check "cd and git add before the commit still allowed" allow "$mention" "$(pr $'cd /tmp && git add -A && git commit -q -F - <<\'EOF\' 2>&1 | tail -3\nfix parser\nEOF')"
# bounds: a long line of repeated message files and a named pipe must be denied quickly
timed() {  # timed NAME LIMIT-SECONDS PAYLOAD-FILE
  local name="$1" limit="$2" file="$3" t0 t1 out
  t0=$(date +%s%N); out="$(timeout 60 python3 "$pyhook" < "$file")"; t1=$(date +%s%N)
  local ms=$(( (t1 - t0) / 1000000 ))
  if grep -q '"permissionDecision": *"deny"' <<<"$out" && [ "$ms" -lt $((limit * 1000)) ]; then
    pass=$((pass + 1)); echo "ok   - $name (${ms} ms)"
  else fail=$((fail + 1)); echo "FAIL - $name (${ms} ms, limit ${limit}s, output: ${out:0:80})"; fi
}
big="$HOME/big.json"
python3 - "$big" <<'PYEOF'
import json, sys
cmd = "git commit -m 'Generated with Claude Code' " + "-F x " * 20000
json.dump({"tool_name": "Bash", "tool_input": {"command": cmd}}, open(sys.argv[1], "w"))
PYEOF
timed "100 KB of repeated -F denied within 5 s" 5 "$big"
fifo_dir="$(mktemp -d)"; mkfifo "$fifo_dir/ff"
jq -n --arg c "git commit -F ff;" --arg d "$fifo_dir" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' > "$HOME/fifo.json"
timed "named pipe with glued punctuation denied within 5 s, never opened" 5 "$HOME/fifo.json"
jq -n --arg c "git commit -F $fifo_dir/ff" '{tool_name:"Bash",tool_input:{command:("cd /tmp; " + $c + ";")}}' > "$HOME/fifo2.json"
timed "named pipe by absolute path with glued punctuation denied within 5 s" 5 "$HOME/fifo2.json"
rm -rf "$fifo_dir"
# the differential corpus against the pinned copy of the hook as it was on main
diff_out="$(python3 "$here/no-agent-mention-diff.py" 2>&1)"; diff_rc=$?
if [ "$diff_rc" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - differential: $(grep '^corpus:' <<<"$diff_out")"
else fail=$((fail + 1)); echo "FAIL - differential against the pinned baseline hook"; grep -E 'FAIL|passed|^ ' <<<"$diff_out" | sed 's/^/       /'; fi

# the completion gate suite (its own script; counted here as one result)
cg_out="$(bash "$here/run-completion-gate-tests.sh" 2>&1)"; cg_rc=$?
if [ "$cg_rc" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - completion-gate suite: $(grep '^passed:' <<<"$cg_out")"
else fail=$((fail + 1)); echo "FAIL - completion-gate suite"; grep -E '^FAIL|^passed' <<<"$cg_out" | sed 's/^/       /'; fi

# the brain-task-sync evidence script suite (its own script; counted here as one result)
bt_out="$(bash "$here/run-brain-task-sync-tests.sh" 2>&1)"; bt_rc=$?
if [ "$bt_rc" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - brain-task-sync suite: $(tail -1 <<<"$bt_out")"
else fail=$((fail + 1)); echo "FAIL - brain-task-sync suite"; grep -E '^FAIL|passed' <<<"$bt_out" | sed 's/^/       /'; fi

# --- fallbacks say so on standard error, never on the hook's output ---
# check_err NAME SCRIPT PAYLOAD STDOUT-EXPECT(exact) STDERR-REGEX (empty regex: stderr must be empty)
check_err() {
  local name="$1" script="$2" payload="$3" want="$4" re="$5" out err rc ef; ef="$(mktemp)"
  out="$(printf '%s' "$payload" | $script 2>"$ef")"; rc=$?; err="$(cat "$ef")"; rm -f "$ef"
  if [ "$rc" -eq 0 ] && [ "$out" = "$want" ] && { [ -z "$re" ] && [ -z "$err" ] || { [ -n "$re" ] && grep -qE "$re" <<<"$err"; }; }; then
    pass=$((pass + 1)); echo "ok   - $name"
  else fail=$((fail + 1)); echo "FAIL - $name (rc=$rc out=[$out] err=[$err])"; fi
}
iso="$(mktemp -d)"; mkdir "$iso/hooks"; cp "$(dirname "$pyhook")/no-agent-mention.py" "$iso/hooks/"
cp "$hooks/delegate-gate.sh" "$hooks/_gate-common.sh" "$hooks/_bash-write-check.py" "$iso/"
vm="$(pr 'M="Generated with Claude Code"; git commit -m "$M"')"
check_err "no walker: hook output unchanged and a note on stderr" "python3 $iso/hooks/no-agent-mention.py" "$vm" '{}' 'no-agent-mention: .*walker'
mkdir "$iso/local-hooks"; echo 'raise RuntimeError("broken")' > "$iso/local-hooks/_cmd_dirs.py"
check_err "broken walker: hook output unchanged and a note on stderr" "python3 $iso/hooks/no-agent-mention.py" "$vm" '{}' 'no-agent-mention: .*walker'
check_err "no walker needed: plain commit is silent on stderr" "python3 $iso/hooks/no-agent-mention.py" "$(pr 'git commit -m "fix parser"')" '{}' ''
check_err "working walker: no stderr" "$mention" "$vm" "$(printf '%s' "$vm" | $mention)" ''
check_err "malformed input: allowed with a note" "$mention" 'not json' '{}' 'no-agent-mention: malformed'
check_err "empty input: allowed with a note" "$mention" '' '{}' 'no-agent-mention: malformed'
check_err "no walker: delegate gate allows a variable target with a note" "bash $iso/delegate-gate.sh" "$(bash_payload 'F=/abs/file; echo hi > "$F"')" '' 'delegate-gate: .*walker'
check_err "no walker: delegate gate literal deny has no note" "bash $iso/delegate-gate.sh" "$(bash_payload 'echo hi > /abs/file')" "$(printf '%s' "$(bash_payload 'echo hi > /abs/file')" | bash "$hooks/delegate-gate.sh")" ''
check_err "working walker: delegate gate is silent on stderr" "$gate" "$(bash_payload 'F=$(mktemp); echo hi > "$F"')" '' ''
rm -rf "$iso"


# the brain-task-reminder hook suite (its own script; counted here as one result)
btr_out="$(bash "$here/run-brain-task-reminder-tests.sh" 2>&1)"; btr_rc=$?
if [ "$btr_rc" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - brain-task-reminder suite: $(tail -1 <<<"$btr_out")"
else fail=$((fail + 1)); echo "FAIL - brain-task-reminder suite"; grep -E '^FAIL|passed' <<<"$btr_out" | sed 's/^/       /'; fi

# the wt-reap script suite (its own script; counted here as one result)
wr_out="$(bash "$here/run-wt-reap-tests.sh" 2>&1)"; wr_rc=$?
if [ "$wr_rc" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - wt-reap suite: $(tail -1 <<<"$wr_out")"
else fail=$((fail + 1)); echo "FAIL - wt-reap suite"; grep -E '^FAIL|passed' <<<"$wr_out" | sed 's/^/       /'; fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
