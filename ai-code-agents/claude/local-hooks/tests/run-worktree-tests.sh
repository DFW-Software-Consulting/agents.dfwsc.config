#!/usr/bin/env bash
# Payload-driven tests for worktree-gate.sh (and _git-cmd-scan.py).
# Builds throwaway repos under a temp dir and uses a temporary HOME so the real
# ~/.claude/worktree-gate.off is never read or touched.
# Usage: local-hooks/tests/run-worktree-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_WORKTREE_GATE CLAUDE_WORKTREE_GATE_OFF_FILE
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
git config --global protocol.file.allow always
off="$HOME/.claude/worktree-gate.off"
gate="bash $hooks/worktree-gate.sh"

pass=0; fail=0
check() {
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | $gate 2>&1)"; rc=$?
  if grep -q '"permissionDecision": *"deny"' <<<"$out" && jq -e '.hookSpecificOutput.hookEventName=="PreToolUse" and (.hookSpecificOutput.permissionDecisionReason|type=="string")' <<<"$out" >/dev/null 2>&1; then got=deny; else got=allow; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); echo "ok   - $name"
  else
    fail=$((fail + 1)); echo "FAIL - $name (expected $expect, got $got, rc=$rc)"; echo "       output: $out"
  fi
}
silent() {  # NAME PAYLOAD: exit 0 and no output
  local out rc
  out="$(printf '%s' "$2" | $gate 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (rc=$rc, output: $out)"; fi
}

# --- fixtures ---
T="$(mktemp -d "$HOME/t.XXXXXX")"
primary="$T/primary"; wt="$T/wt"; plain="$T/plain"; unborn="$T/unborn"; sub="$T/superproj"
git init -q "$primary"; echo "ignored.txt" > "$primary/.gitignore"; mkdir "$primary/src"; echo a > "$primary/src/a.txt"
git -C "$primary" add -A; git -C "$primary" commit -qm init
git -C "$primary" worktree add -q -b feat "$wt"
mkdir "$plain"; git init -q "$unborn"
git init -q "$T/inner"; echo x > "$T/inner/f"; git -C "$T/inner" add -A; git -C "$T/inner" commit -qm i
git init -q "$sub"; git -C "$sub" submodule -q add "$T/inner" vendor 2>/dev/null; git -C "$sub" commit -qm withsub
ln -s "$primary/src" "$T/link-into-primary"
ln -s "$wt" "$T/link-into-wt"

fp() { jq -n --arg p "$1" --arg c "${2:-$plain}" '{tool_name:"Edit",cwd:$c,tool_input:{file_path:$p}}'; }
fpa() { jq -n --arg p "$1" '{tool_name:"Write",agent_id:"a1",cwd:"/",tool_input:{file_path:$p}}'; }
nb() { jq -n --arg p "$1" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}'; }
bp() { jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }

# --- file tools ---
check "Edit in primary checkout denied" deny "$(fp "$primary/src/a.txt")"
check "Edit in primary checkout denied (subagent)" deny "$(fpa "$primary/src/a.txt")"
check "Edit in linked worktree allowed" allow "$(fp "$wt/src/a.txt")"
check "Edit in linked worktree allowed (subagent)" allow "$(fpa "$wt/src/a.txt")"
check "Edit outside any repo allowed" allow "$(fp "$plain/x.txt")"
check "Edit in unborn repo allowed" allow "$(fp "$unborn/x.txt")"
check "Edit of git-ignored file in primary allowed" allow "$(fp "$primary/ignored.txt")"
check "symlink into primary checkout denied" deny "$(fp "$T/link-into-primary/a.txt")"
check "symlink into linked worktree allowed" allow "$(fp "$T/link-into-wt/src/a.txt")"
check "NotebookEdit in primary denied" deny "$(nb "$primary/src/n.ipynb")"
check "NotebookEdit in worktree allowed" allow "$(nb "$wt/src/n.ipynb")"
check "new file in not-yet-existing subdir of primary denied" deny "$(fp "$primary/new/deeper/x.txt")"
check "new file in not-yet-existing subdir of worktree allowed" allow "$(fp "$wt/new/deeper/x.txt")"
check "relative path resolved against cwd (primary) denied" deny "$(fp "src/a.txt" "$primary")"
check "submodule of a repo with a primary superproject denied" deny "$(fp "$sub/vendor/f")"
check "ignored file in not-yet-existing dir allowed" allow "$(fp "$primary/ignored.txt/x")"
check "payload with no path allowed" allow '{"tool_name":"Edit","tool_input":{}}'
out="$(printf '%s' "$(fp "$primary/src/a.txt")" | $gate)"
if jq -e '.hookSpecificOutput.permissionDecisionReason | test("'"$primary"'") and test("git worktree add -b <branch> ~/worktrees/<repo>-<slug> origin/main") and test("worktree-gate.off") and test("CLAUDE_WORKTREE_GATE=off")' <<<"$out" >/dev/null; then
  pass=$((pass + 1)); echo "ok   - denial names root, worktree command and escape hatch"
else fail=$((fail + 1)); echo "FAIL - denial message: $out"; fi

# --- Bash ---
check "git commit with cwd primary denied" deny "$(bp 'git commit -m x' "$primary")"
check "git commit with cwd primary denied (subagent)" deny "$(bp 'git commit -m x' "$primary" | jq '.agent_id="a1"')"
check "git commit with cwd worktree allowed" allow "$(bp 'git commit -m x' "$wt")"
check "git -C worktree commit from primary cwd allowed" allow "$(bp "git -C $wt commit -m x" "$primary")"
check "git -C primary commit from worktree cwd denied" deny "$(bp "git -C $primary commit -m x" "$wt")"
check "git -C . -C worktree repeated allowed" allow "$(bp "git -C $primary -C $wt commit -m x" "$plain")"
check "cd worktree && git commit allowed" allow "$(bp "cd $wt && git commit -m x" "$primary")"
check "cd primary && git stash denied" deny "$(bp "cd $primary && git stash" "$plain")"
check "cd primary then git -C worktree allowed" allow "$(bp "cd $primary && git -C $wt commit -m x" "$plain")"
check "subshell cd does not leak: denied after" deny "$(bp "(cd $wt && true); git add -A" "$primary")"
check "git stash list allowed" allow "$(bp 'git stash list' "$primary")"
check "git stash show allowed" allow "$(bp 'git stash show -p' "$primary")"
check "git stash push denied" deny "$(bp 'git stash push -u -m x' "$primary")"
check "git status allowed" allow "$(bp 'git status' "$primary")"
check "git log allowed" allow "$(bp 'git log --oneline' "$primary")"
check "git fetch allowed" allow "$(bp 'git fetch origin' "$primary")"
check "git pull allowed (fast-forwarding main)" allow "$(bp 'git pull --ff-only' "$primary")"
check "git worktree add in primary allowed" allow "$(bp 'git worktree add -b x ../x origin/main' "$primary")"
check "git branch / tag / diff / push allowed" allow "$(bp 'git branch -D x; git tag v1; git diff; git push origin x' "$primary")"
check "git checkout -b x in primary denied" deny "$(bp 'git checkout -b x' "$primary")"
check "git switch in primary denied" deny "$(bp 'git switch main' "$primary")"
check "git add / reset / rebase / merge in primary denied" deny "$(bp 'git fetch && git rebase origin/main' "$primary")"
for s in restore cherry-pick revert am apply clean rm mv reset merge add; do
  check "git $s in primary denied" deny "$(bp "git $s x" "$primary")"
done
check "global options before subcommand still denied" deny "$(bp 'git --no-pager -c core.editor=true commit -m x' "$primary")"
check "echo \"git commit\" allowed" allow "$(bp 'echo "git commit"' "$primary")"
check "grep -r 'git stash' . allowed" allow "$(bp "grep -r 'git stash' ." "$primary")"
check "echo git commit (argument words) allowed" allow "$(bp 'echo git commit' "$primary")"
check "FOO=1 git commit denied" deny "$(bp 'FOO=1 git commit -m x' "$primary")"
check "env FOO=1 git commit denied" deny "$(bp 'env FOO=1 git commit -m x' "$primary")"
check "git commit after && denied" deny "$(bp 'ls && git commit -m x' "$primary")"
check "cd \"\$DIR\" && git commit allowed (not literal)" allow "$(bp 'cd "$DIR" && git commit -m x' "$primary")"
check "cd - && git commit allowed" allow "$(bp 'cd - && git commit -m x' "$primary")"
check "cd \$(pwd) && git commit allowed" allow "$(bp 'cd $(mktemp -d) && git commit -m x' "$primary")"
check "git -C \"\$D\" commit allowed (not literal)" allow "$(bp 'git -C "$D" commit -m x' "$primary")"
check "git commit in non-repo allowed" allow "$(bp 'git commit -m x' "$plain")"
check "git commit in unborn repo allowed" allow "$(bp 'git commit -m x' "$unborn")"
check "git add in submodule of primary superproject denied" deny "$(bp 'git add -A' "$sub/vendor")"
check "relative cd resolved against cwd" deny "$(bp 'cd src && git add -A' "$primary")"
check "command without git word allowed" allow "$(bp 'ls -la' "$primary")"
check "heredoc body mentioning git commit allowed" allow "$(bp $'cat <<EOF\ngit commit -m x\nEOF' "$primary")"
check "unparseable command allowed" allow "$(bp "git commit -m 'oops" "$primary")"

# --- escape hatch ---
edit_primary="$(fp "$primary/src/a.txt")"
touch "$off"
check "fresh off-file allows" allow "$edit_primary"
check "fresh off-file allows Bash" allow "$(bp 'git commit -m x' "$primary")"
touch -d '13 hours ago' "$off"
check "13h-old off-file does not allow" deny "$edit_primary"
if printf '%s' "$edit_primary" | $gate | grep -q 'expired'; then pass=$((pass + 1)); echo "ok   - denial says the off-file expired"
else fail=$((fail + 1)); echo "FAIL - expiry note missing"; fi
[ -e "$off" ] && { pass=$((pass + 1)); echo "ok   - stale off-file not deleted"; } || { fail=$((fail + 1)); echo "FAIL - stale off-file deleted"; }
touch -d '+2 hours' "$off"
check "future-dated off-file does not allow" deny "$edit_primary"
rm -f "$off"
check "no off-file: denied" deny "$edit_primary"
if printf '%s' "$edit_primary" | $gate | grep -q 'expired'; then fail=$((fail + 1)); echo "FAIL - expiry note without off-file"; else pass=$((pass + 1)); echo "ok   - no expiry note without an off-file"; fi
export CLAUDE_WORKTREE_GATE=off
check "env off allows" allow "$edit_primary"
unset CLAUDE_WORKTREE_GATE
export CLAUDE_WORKTREE_GATE_OFF_FILE="$HOME/custom.off"; touch "$CLAUDE_WORKTREE_GATE_OFF_FILE"
check "off-file path override honoured" allow "$edit_primary"
unset CLAUDE_WORKTREE_GATE_OFF_FILE
touch "$HOME/.claude/delegate-gate.off"
check "delegate-gate off-file does not disable worktree gate" deny "$edit_primary"
rm -f "$HOME/.claude/delegate-gate.off"
iso="$(mktemp -d)"; cp "$hooks/worktree-gate.sh" "$iso/"; touch "$off"
check_iso() { local out; out="$(printf '%s' "$edit_primary" | bash "$iso/worktree-gate.sh" 2>&1)"; if grep -q '"permissionDecision": *"deny"' <<<"$out"; then pass=$((pass + 1)); echo "ok   - missing shared file behaves as gate ON"; else fail=$((fail + 1)); echo "FAIL - missing shared file: $out"; fi; }
check_iso
rm -f "$off"; rm -rf "$iso"

# --- fail open on bad input ---
silent "empty stdin exits 0 silently" ''
silent "malformed JSON exits 0 silently" '{not json'
silent "JSON non-object exits 0 silently" '[1,2]'
silent "empty object exits 0 silently" '{}'

# --- denial shape ---
out="$(printf '%s' "$(bp 'git commit -m x' "$primary")" | $gate)"
if jq -e '(.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null; then
  pass=$((pass + 1)); echo "ok   - Bash denial is valid JSON in the PreToolUse deny shape"
else fail=$((fail + 1)); echo "FAIL - Bash denial shape: $out"; fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
