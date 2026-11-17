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
check "no walker: body message still denied (a quoted word holding commit is read as a command)" deny "python3 $iso/hooks/no-agent-mention.py" "$(pr "bash -c 'git commit -m \"Generated with Claude Code\"'")"
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

# --- fallbacks say so on standard error, never on the hook's output ---
# check_err NAME SCRIPT PAYLOAD STDOUT-EXPECT(exact) STDERR-REGEX (empty regex: stderr must be empty)
check_err() {
  local name="$1" script="$2" payload="$3" want="$4" re="$5" out err rc ef; ef="$(mktemp)"
  out="$(printf '%s' "$payload" | $script 2>"$ef")"; rc=$?; err="$(cat "$ef")"; rm -f "$ef"
  if [ "$rc" -eq 0 ] && [ "$out" = "$want" ] && { [ -z "$re" ] && [ -z "$err" ] || { [ -n "$re" ] && grep -qE "$re" <<<"$err"; }; }; then
    pass=$((pass + 1)); echo "ok   - $name"
  else fail=$((fail + 1)); echo "FAIL - $name (rc=$rc out=[$out] err=[$err])"; fi
}
# --- no-agent-mention.py: here-document messages (git commit -F -) and what counts as a commit ---
hd_clean="$(printf '%s\n' "git commit -F - <<'EOF'" "fix(parser): handle empty input" "" "Body that doesn't mention any tool." "EOF")"
hd_bad="$(printf '%s\n' "git commit -F - <<'EOF'" "fix(parser): handle empty input" "" "Generated with Claude Code" "EOF")"
hd_trailer="$(printf '%s\n' "git commit -F - <<EOF" "fix: x" "" "Co-Authored-By: Claude <a@b.c>" "EOF")"
check "heredoc -F - clean message allowed" allow "$mention" "$(pr "$hd_clean")"
check "heredoc -F - with agent credit denied" deny "$mention" "$(pr "$hd_bad")"
check "heredoc -F - unquoted delimiter, trailer denied" deny "$mention" "$(pr "$hd_trailer")"
check "git add && heredoc commit, clean allowed" allow "$mention" "$(pr "git add -A && $hd_clean")"
check "heredoc body words -m/-F not read as options" allow "$mention" "$(pr "$(printf '%s\n' "git commit -F - <<'EOF'" "fix: x" "-m Claude" "-F nothing" "EOF")")"
check "-F - with no heredoc still denied (unreadable)" deny "$mention" "$(pr 'echo "fix: x" | git commit -F -')"
check "-F unreadable file still denied" deny "$mention" "$(pr 'git commit -F /nonexistent/msg.txt')"
check "echo with the words git and commit ignored" allow "$mention" "$(pr 'echo "remember to git commit later" | tee notes.txt; ls -F /nonexistent')"
check "grep for 'git commit' ignored" allow "$mention" "$(pr 'grep -rn "git commit" docs/ -F /nonexistent/list.txt')"
check "path containing commit not a commit" allow "$mention" "$(pr 'cat git/commit-msg-template -F /nonexistent/x')"
check "later ls -F after a real commit not read as its message file" allow "$mention" "$(pr 'git commit -m "fix parser" && ls -F /nonexistent')"
check "commit after cd and ; still judged" deny "$mention" "$(pr 'cd /tmp; git commit -m "Generated with Claude Code"')"
check "git -C dir commit still judged" deny "$mention" "$(pr 'git -C /tmp commit -m "Co-Authored-By: Claude <a@b.c>"')"
check "env VAR= git commit still judged" deny "$mention" "$(pr 'GIT_AUTHOR_NAME=x git commit -m "Generated with Claude Code"')"
# --- no-agent-mention.py: fail closed on what counts as a commit (review of the narrowed detection) ---
nl=$'\n'; gw='Generated with Claude Code'
# finding 1: a line break or a backslash-newline separates commands
check "commit on a new line after git add denied" deny "$mention" "$(pr "git add -A${nl}git commit -m \"$gw\"")"
check "commit on a new line after cd denied" deny "$mention" "$(pr "cd /tmp${nl}git commit -m \"$gw\"")"
check "commit after && backslash-newline denied" deny "$mention" "$(pr "git add -A && \\${nl}git commit -m \"$gw\"")"
check "commit on a new line, clean allowed" allow "$mention" "$(pr "git add -A${nl}git commit -m \"fix parser\"")"
# finding 2: groupings, wrappers, substitutions and a glued pipe
check "brace group commit denied" deny "$mention" "$(pr "{ git commit -m \"$gw\"; }")"
check "timeout wrapper commit denied" deny "$mention" "$(pr "timeout 5 git commit -m \"$gw\"")"
check "xargs commit denied" deny "$mention" "$(pr "echo x | xargs git commit -m \"$gw\"")"
check "commit inside \$( ) denied" deny "$mention" "$(pr "echo \$(git commit -m \"$gw\")")"
check "commit inside backticks denied" deny "$mention" "$(pr "echo \`git commit -m \"$gw\"\`")"
check "commit inside a double-quoted \$( ) denied" deny "$mention" "$(pr "echo \"\$(git commit -m '$gw')\"")"
check "glued pipe into commit denied" deny "$mention" "$(pr "echo x|git commit -m \"$gw\"")"
check "unknown wrapper (watch) holding a commit denied" deny "$mention" "$(pr "watch -n1 'git commit -m \"$gw\"'")"
check "find -exec commit denied" deny "$mention" "$(pr "find . -exec git commit -m \"$gw\" \;")"
check "variable holding git denied" deny "$mention" "$(pr "g=git; \$g commit -m \"$gw\"")"
check "alias for git denied" deny "$mention" "$(pr "alias g=git; g commit -m \"$gw\"")"
check "substituted subcommand denied" deny "$mention" "$(pr "git \$(echo commit) -m \"$gw\"")"
check "brace group, clean allowed" allow "$mention" "$(pr "{ git commit -m \"fix parser\"; }")"
check "timeout wrapper, clean allowed" allow "$mention" "$(pr "timeout 5 git commit -m \"fix parser\"")"
# finding 3: a standard-input message file is fed only by a here-document in its own pipeline
check "second commit piped a credit after a clean here-document denied" deny "$mention" "$(pr "git commit -F - <<'EOF'${nl}fix: one${nl}EOF${nl}echo \"$gw\" | git commit -F -")"
check "first here-document credits, second commit piped clean: denied" deny "$mention" "$(pr "git commit -F - <<'EOF'${nl}$gw${nl}EOF${nl}echo ok | git commit -F -")"
check "two here-document operators on one line (one body split off) denied" deny "$mention" "$(pr "cat > /dev/null <<A ; git commit -F - <<B${nl}A${nl}$gw${nl}B")"
check "cat here-document piped into commit, clean allowed" allow "$mention" "$(pr "cat <<'EOF' | git commit -F -${nl}fix: x${nl}EOF")"
check "cat here-document piped into commit, credit denied" deny "$mention" "$(pr "cat <<'EOF' | git commit -F -${nl}$gw${nl}EOF")"
check "-F /dev/stdin here-document credit denied" deny "$mention" "$(pr "git commit -F /dev/stdin <<'EOF'${nl}$gw${nl}EOF")"
check "-F /dev/stdin here-document clean allowed" allow "$mention" "$(pr "git commit -F /dev/stdin <<'EOF'${nl}fix: x${nl}EOF")"
check "-F /dev/stdin from a pipe denied (unreadable)" deny "$mention" "$(pr 'printf "fix" | git commit -F /dev/stdin')"
check "-F - here-string still denied" deny "$mention" "$(pr 'git commit -F - <<< "fix"')"
check "here-document run by bash holding a credited commit denied" deny "$mention" "$(pr "bash <<'EOF'${nl}git commit -m \"$gw\"${nl}EOF")"
check "file written by a here-document, then a clean commit allowed" allow "$mention" "$(pr "cat > notes.md <<'EOF'${nl}It's about $gw${nl}EOF${nl}git add notes.md && git commit -m docs")"
# still not judged: commands that are provably not commits
check "echo of a credited commit line not judged" allow "$mention" "$(pr "echo git commit -m \"$gw\"")"
check "git log search not judged" allow "$mention" "$(pr "git log --grep \"$gw\" -m -- commit")"
# finding 5: split_heredocs here and in _public-text-check.py stay the same
pin_out="$(python3 - "$pyhook" "$hooks/_public-text-check.py" 2>&1 <<'PYEOF'
import ast, importlib.util, sys
def load(n, p):
    s = importlib.util.spec_from_file_location(n, p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
a, b = load("nam_pin", sys.argv[1]), load("ptc_pin", sys.argv[2])
def body(path):
    tree = ast.parse(open(path).read())
    f = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "split_heredocs")
    if f.body and isinstance(f.body[0], ast.Expr) and isinstance(getattr(f.body[0], "value", None), ast.Constant):
        f.body = f.body[1:]  # docstrings may differ
    return ast.dump(f)
assert body(sys.argv[1]) == body(sys.argv[2]), "split_heredocs code differs"
cases = ["git commit -F - <<'EOF'\nx\nEOF", "a <<-\"E\"\n\tb\n\tE\nc", "x <<<y\nz", "a <<E\nno end", "cat <<\\E\nq\nE", ""]
for c in cases:
    assert a.split_heredocs(c) == b.split_heredocs(c), c
print("same")
PYEOF
)"
[ "$pin_out" = same ] && { pass=$((pass + 1)); echo "ok   - split_heredocs pinned to _public-text-check.py"; } || { fail=$((fail + 1)); echo "FAIL - split_heredocs differs from _public-text-check.py: $pin_out"; }
# the differential corpus against the pinned baseline hook
diff_out="$(python3 "$here/no-agent-mention-diff.py" 2>&1)"; diff_rc=$?
if [ "$diff_rc" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - differential: $(grep '^corpus:' <<<"$diff_out")"
else fail=$((fail + 1)); echo "FAIL - differential against the baseline hook"; grep -E 'FAIL|passed' <<<"$diff_out" | sed 's/^/       /'; fi

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

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
