#!/usr/bin/env bash
# Payload-driven tests for checks-gate.sh. Throwaway repos (each with a local
# bare origin), stamps made by the real run-checks.sh from .claude/git-checks
# files of plain shell commands, a temp HOME and a temp config file.
# Usage: local-hooks/tests/run-checks-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_CHECKS_GATE CHECKS_GATE_TODAY
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
export CLAUDE_CHECKS_GATE_CONF="$HOME/checks-gate.conf"
gate="bash $hooks/checks-gate.sh"
rc="$hooks/run-checks.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }
# classify PAYLOAD -> silent | warn | deny | other
classify() {
  local out; out="$(printf '%s' "$1" | $gate 2>&1)"
  if [ -z "$out" ]; then echo silent
  elif jq -e '.permissionDecision? == null and (.systemMessage|type=="string") and (.hookSpecificOutput|keys)==["additionalContext","hookEventName"] and .hookSpecificOutput.hookEventName=="PreToolUse" and (.hookSpecificOutput.additionalContext|type=="string")' <<<"$out" >/dev/null 2>&1; then echo warn
  elif jq -e '(.hookSpecificOutput|keys)==["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.hookEventName=="PreToolUse"' <<<"$out" >/dev/null 2>&1; then echo deny
  else echo "other:$out"; fi
}
check() {  # NAME EXPECT PAYLOAD
  local got; got="$(classify "$3")"
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "expected $2, got $got"; fi
}

T="$(mktemp -d "$HOME/t.XXXXXX")"
elsewhere="$T/elsewhere"; mkdir "$elsewhere"
bp() { jq -n --arg c "$1" --arg d "${2:-$elsewhere}" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
# mkrepo NAME CHECKS: repo on branch feat, bare origin (main), one code commit on feat, no upstream.
mkrepo() {
  local n="$1" d="$T/$1"
  git init -q --bare -b main "$T/$n.git"; git init -q -b main "$d"
  echo a > "$d/a.txt"
  if [ -n "${2:-}" ]; then mkdir -p "$d/.claude"; printf '%s\n' "$2" > "$d/.claude/git-checks"; fi
  git -C "$d" add -A; git -C "$d" commit -qm init
  git -C "$d" remote add origin "$T/$n.git"; git -C "$d" push -q origin main
  git -C "$d" fetch -q origin; git -C "$d" remote set-head origin main >/dev/null
  git -C "$d" checkout -q -b feat; echo b > "$d/code.txt"; git -C "$d" add -A; git -C "$d" commit -qm code
}
stamp() { bash "$rc" --dir "$1" >/dev/null 2>&1; }
stampfile() { echo "$1/.git/claude-checks/$(git -C "$1" rev-parse HEAD).json"; }
mode_warn() { printf 'MODE=warn\n' > "$CLAUDE_CHECKS_GATE_CONF"; }
mode_deny() { printf 'MODE=deny\n' > "$CLAUDE_CHECKS_GATE_CONF"; }
push() { bp "${1:-git push origin feat}" "${2:-$p}"; }

mkrepo r "true"; r="$T/r"; mkrepo p "true"; p="$T/p"
mkrepo nochk ""; mkrepo none "none"
mkrepo bad "true"; mkrepo stale "true"; mkrepo added "true"; mkrepo edited "true"; mkrepo wrongtree "true"
mkrepo failing "false"; mkrepo broken "true"
mkrepo docs "true"; mkrepo mixed "true"; mkrepo up "true"
snap() { for d in r p nochk none stale added edited wrongtree failing broken docs mixed up; do echo "$d $(git -C "$T/$d" rev-parse HEAD) $(git -C "$T/$d" status --porcelain | md5sum) $(git -C "$T/$d" ls-files -s | md5sum) $(ls "$T/$d/.git/claude-checks" 2>/dev/null | md5sum)"; done; }

# --- no checks / valid stamp ---
mode_deny
check "no checks detected allows silently" silent "$(push 'git push origin feat' "$T/nochk")"
check "checks opted out (none) allows silently" silent "$(push 'git push origin feat' "$T/none")"
check "no stamp denies in deny mode" deny "$(push)"
mode_warn
check "no stamp warns in warn mode" warn "$(push)"
rm -f "$CLAUDE_CHECKS_GATE_CONF"
check "no config file defaults to warn" warn "$(push)"
msg="$(printf '%s' "$(push)" | $gate | jq -r .systemMessage)"
case "$msg" in *"$(git -C "$p" rev-parse HEAD | cut -c1-10)"*run-checks.sh*true*) ok "warning names short sha, run-checks.sh and the detected commands";; *) bad "warning text" "$msg";; esac
printf 'MODE=bogus\n' > "$CLAUDE_CHECKS_GATE_CONF"
check "unknown MODE value behaves as warn" warn "$(push)"
mode_deny
stamp "$r"
check "valid stamp allows silently (deny mode)" silent "$(push 'git push origin feat' "$r")"
check "valid stamp allows gh pr create" silent "$(bp 'gh pr create --title x' "$r")"

# --- invalid stamps ---
stamp "$T/bad"; jq '.results[0].exit=1' "$(stampfile "$T/bad")" > "$T/x" && mv "$T/x" "$(stampfile "$T/bad")"
check "hand-edited stamp (exit changed) not valid" deny "$(push 'git push origin feat' "$T/bad")"
stamp "$T/edited"; jq '.detected=["true","true"]' "$(stampfile "$T/edited")" > "$T/x" && mv "$T/x" "$(stampfile "$T/edited")"
check "hand-edited stamp (detected changed) not valid" deny "$(push 'git push origin feat' "$T/edited")"
stamp "$T/failing"
check "failed stamp not valid" deny "$(push 'git push origin feat' "$T/failing")"
stamp "$T/stale"; echo c > "$T/stale/more.txt"; git -C "$T/stale" add -A; git -C "$T/stale" commit -qm more
check "stale stamp from previous commit not valid" deny "$(push 'git push origin feat' "$T/stale")"
stamp "$T/added"; echo 'echo extra' >> "$T/added/.claude/git-checks"
check "stamp missing a newly added check not valid" deny "$(push 'git push origin feat' "$T/added")"
git -C "$T/added" checkout -q -- .claude/git-checks
stamp "$T/wrongtree"; jq '.tree="0000000000000000000000000000000000000000"' "$(stampfile "$T/wrongtree")" > "$T/x" && mv "$T/x" "$(stampfile "$T/wrongtree")"
check "stamp with a wrong tree not valid" deny "$(push 'git push origin feat' "$T/wrongtree")"

# --- DENY_AFTER ---
printf 'MODE=warn\nDENY_AFTER=2026-12-01\n' > "$CLAUDE_CHECKS_GATE_CONF"
CHECKS_GATE_TODAY=2026-11-30 check "DENY_AFTER: day before warns" warn "$(push)"
CHECKS_GATE_TODAY=2026-12-01 check "DENY_AFTER: on the day denies" deny "$(push)"
CHECKS_GATE_TODAY=2026-12-02 check "DENY_AFTER: after denies" deny "$(push)"
printf 'MODE=warn\nDENY_AFTER=nonsense\n' > "$CLAUDE_CHECKS_GATE_CONF"
check "invalid DENY_AFTER ignored" warn "$(push)"
mode_deny

# --- docs-only ---
git -C "$T/docs" reset -q --hard HEAD~1; echo '# d' > "$T/docs/README.md"; mkdir "$T/docs/docs"; echo x > "$T/docs/docs/g.md"
git -C "$T/docs" add -A; git -C "$T/docs" commit -qm docs
check "docs-only change (merge base with default branch) allowed" silent "$(push 'git push origin feat' "$T/docs")"
git -C "$T/mixed" reset -q --hard HEAD~1; echo '# d' > "$T/mixed/README.md"; echo y > "$T/mixed/y.txt"
git -C "$T/mixed" add -A; git -C "$T/mixed" commit -qm mixed
check "mixed docs and code change not allowed" deny "$(push 'git push origin feat' "$T/mixed")"
# upstream present: base is the upstream
git -C "$T/up" push -q -u origin feat
echo '# more' > "$T/up/NOTES.md"; git -C "$T/up" add -A; git -C "$T/up" commit -qm notes
check "upstream present, docs commit on top of pushed code is NOT docs-only" deny "$(push 'git push' "$T/up")"
echo z > "$T/up/z.txt"; git -C "$T/up" add -A; git -C "$T/up" commit -qm z
check "upstream present, code since upstream not allowed" deny "$(push 'git push' "$T/up")"
# docs-only branch that has been pushed: gh pr create is still docs-only
mkrepo pd "true"; git -C "$T/pd" reset -q --hard HEAD~1; echo '# d' > "$T/pd/README.md"; git -C "$T/pd" add -A; git -C "$T/pd" commit -qm docs
git -C "$T/pd" push -q -u origin feat
check "pushed docs-only branch: gh pr create silent" silent "$(bp 'gh pr create --title x' "$T/pd")"
check "pushed docs-only branch: bare push silent" silent "$(push 'git push' "$T/pd")"
check "unpushed docs-only branch: gh pr create silent" silent "$(bp 'gh pr create --title x' "$T/docs")"
# pushed code, then docs on top: the branch contains code, so a stamp is needed
mkrepo pc "true"; git -C "$T/pc" push -q -u origin feat
echo '# n' > "$T/pc/NOTES.md"; git -C "$T/pc" add -A; git -C "$T/pc" commit -qm notes
check "pushed code then docs on top: gh pr create denied" deny "$(bp 'gh pr create --title x' "$T/pc")"
# no base: no remote default branch
git init -q "$T/nobase"; mkdir "$T/nobase/.claude"; echo true > "$T/nobase/.claude/git-checks"; echo '# x' > "$T/nobase/README.md"
git -C "$T/nobase" add -A; git -C "$T/nobase" commit -qm i
check "no base found: docs-only not assumed" deny "$(push 'git push origin main' "$T/nobase")"
# no remote at all and no upstream: no base, so not docs-only (a stamp is required)
check "no remote: docs-only not assumed for gh pr create" deny "$(bp 'gh pr create --title x' "$T/nobase")"

# --- which pushes count ---
git -C "$p" tag v9
check "push of another branch's ref allowed" silent "$(push 'git push origin other:other')"
check "push of another branch name allowed" silent "$(push 'git push origin other')"
check "push --dry-run ignored" silent "$(push 'git push --dry-run origin feat')"
check "push -n ignored" silent "$(push 'git push -n origin feat')"
check "push --delete ignored" silent "$(push 'git push origin --delete old')"
check "push -d ignored" silent "$(push 'git push -d origin old')"
check "tags-only push ignored" silent "$(push 'git push --tags')"
check "push of current branch by name judged" deny "$(push 'git push origin feat')"
check "push HEAD judged" deny "$(push 'git push origin HEAD')"
check "push HEAD:refs/heads/x judged" deny "$(push 'git push origin HEAD:refs/heads/x')"
check "bare push judged" deny "$(push 'git push')"
check "unrelated git command ignored" silent "$(push 'git status')"
check "non-git command ignored" silent "$(push 'ls')"
check "git word in quotes ignored" silent "$(push "echo 'git push origin feat'")"

# --- gh pr create ---
check "gh pr create from the repo directory judged" deny "$(bp 'gh pr create --title x' "$p")"
check "gh pr create with --repo skipped" silent "$(bp 'gh pr create --repo o/x --title x' "$p")"
check "gh pr create with -R skipped" silent "$(bp 'gh pr create -R o/x --title x' "$p")"
check "cd <repo> && gh pr create judged" deny "$(bp "cd $p && gh pr create --title x")"
check "gh pr list ignored" silent "$(bp 'gh pr list' "$p")"
check "gh pr create outside any repo allowed" silent "$(bp 'gh pr create --title x' "$elsewhere")"

# --- directory ---
check "git -C <repo> push judged from another cwd" deny "$(bp "git -C $p push origin feat")"
check "cd <repo> && git push judged" deny "$(bp "cd $p && git push origin feat")"
check "undeterminable cd (deny mode) now denied" deny "$(bp 'cd "$X" && git push origin feat')"
check "undeterminable -C (deny mode) now denied" deny "$(bp 'git -C "$X" push origin feat')"
check "missing directory allowed" silent "$(bp 'git push origin feat' "$T/nope")"
check "subagent payload judged too" deny "$(push | jq '.agent_id="a1"')"

# --- unknown directory: fail closed ---
sp="$T/sp dir"; mkdir "$sp"; ln -s "$p" "$sp/wt1"   # $S/wt1 resolves to the unstamped repo p
unk() {  # NAME COMMAND: deny in deny mode, warn in warn mode, from an unrelated cwd
  mode_deny; check "$1 (deny)" deny "$(bp "$2")"
  mode_warn; check "$1 (warn)" warn "$(bp "$2")"
  mode_deny
}
unk "reproduced: W=<abs> && cd \"\$W\" && git push" "W=$p && cd \"\$W\" && git push -u origin feat"
unk "reproduced: S=<abs>; cd \$S/wt1 && git push" 'S=$(echo /x); cd $S/wt1 && git push -u origin feat/x'
unk 'cd "$W" && git push' 'cd "$W" && git push origin feat'
unk 'cd $W/sub && git push' 'cd $W/sub && git push origin feat'
unk 'pushd "$W" && git push' 'pushd "$W" && git push origin feat'
unk 'cd $(pwd)/x && git push' 'cd $(pwd)/x && git push origin feat'
unk 'cd - && git push' 'cd - && git push origin feat'
unk 'git -C "$W" push' 'git -C "$W" push origin feat'
unk 'git -C "$(pwd)/x" push' 'git -C "$(pwd)/x" push origin feat'
unk 'git -C $(pwd)/x push (glued)' 'git -C $(pwd)/x push origin main'
unk 'git -C `pwd`/x push (glued)' 'git -C `pwd`/x push origin main'
unk 'git -C "$(pwd)"/x push (glued)' 'git -C "$(pwd)"/x push origin main'
unk 'git -C pre$(pwd)post push (glued)' 'git -C pre$(pwd)post push origin main'
unk 'git --git-dir=$(pwd)/.git push (glued)' 'git --git-dir=$(pwd)/.git push origin main'
unk 'git --work-tree=$(pwd)/x push (glued)' 'git --work-tree=$(pwd)/x push origin main'
unk 'git -C $(pwd) push (bare substitution)' 'git -C $(pwd) push origin main'
unk 'git -C $(git rev-parse --show-toplevel) push' 'git -C $(git rev-parse --show-toplevel) push origin main'
unk 'bash -c with a glued -C substitution' "bash -c 'git -C \$(pwd)/x push origin main'"
unk 'eval with a glued -C substitution' 'eval git -C $(pwd)/x push origin main'
unk 'prefix assignment holding a glued substitution' 'GIT_DIR=$(pwd)/x/.git git push origin main'
unk 'wrapper, glued substitution in the directory' 'timeout 5 git -C $(pwd)/a push origin main'
unk 'env -C with a substitution directory' 'env -C $(pwd)/a git push origin main'
unk 'GIT_DIR=$X git push' 'GIT_DIR=$X git push origin feat'
unk 'git --git-dir="$X" push' 'git --git-dir="$X" push origin feat'
unk 'git --work-tree $X push' 'git --work-tree $X push origin feat'
unk '(cd "$W" && git push)' '(cd "$W" && git push origin feat)'
unk 'popd then push' 'popd && git push origin feat'
unk 'cd "$W" && gh pr create' 'cd "$W" && gh pr create --title x'
unk 'cd $W/sub && gh pr create' 'cd $W/sub && gh pr create --title x'
unk 'pushd "$W" && gh pr create' 'pushd "$W" && gh pr create --title x'
unk '(cd "$W" && gh pr create)' '(cd "$W" && gh pr create --title x)'
unk 'bash -c with variable cd and push' "bash -c 'cd \"\$W\" && git push origin feat'"
unk 'sh -c with git -C variable' "sh -c 'git -C \$W push origin feat'"
unk 'eval with variable cd and push' 'eval "cd $W && git push origin feat"'
unk 'bash -c with gh pr create after variable cd' "bash -c 'cd \$W && gh pr create --title x'"
unk 'push of another branch ref is not exempt with unknown dir' 'cd "$W" && git push origin other:other'
unk 'cd back to unknown after a known dir' "cd $p && cd \"\$W\" && git push origin feat"
mode_deny
msg="$(printf '%s' "$(bp 'cd "$W" && git push -u origin feat/x')" | $gate | jq -r .hookSpecificOutput.permissionDecisionReason)"
case "$msg" in
  *"could not tell which repository"*"git -C /absolute/path push"*"cd /absolute/path && git push"*"another branch"*"CLAUDE_CHECKS_GATE=off"*) ok "unknown-dir message: could not tell, literal-path advice, repo-only exemptions, escape hatch";;
  *) bad "unknown-dir message" "$msg";;
esac
out="$(printf '%s' "$(bp 'cd "$W" && gh pr create')" | $gate | jq -r .hookSpecificOutput.permissionDecisionReason)"
case "$out" in *"could not tell which repository this gh pr create"*) ok "unknown-dir message names gh pr create";; *) bad "gh message" "$out";; esac
# text-only exemptions still apply with an unknown directory
for ex in 'git push --dry-run origin feat' 'git push -n origin feat' 'git push origin --delete old' 'git push -d origin old' 'git push --tags'; do
  check "unknown dir, text-only exemption silent: $ex" silent "$(bp "cd \"\$W\" && $ex")"
  check "unknown -C, text-only exemption silent: $ex" silent "$(bp "git -C \"\$W\" ${ex#git }")"
done
# a push behind a wrapper is judged like a bare push
for w in 'timeout 5' 'timeout --signal=KILL 5' 'sudo' 'sudo -u root' 'nice' 'nice -n 5' 'env' 'env -u FOO' 'env FOO=1' 'ionice -c 3' 'stdbuf -oL' 'setsid' 'doas'; do
  check "wrapped push, unstamped repo denied: $w" deny "$(bp "$w git -C $p push origin feat")"
  check "wrapped push, passing record silent: $w" silent "$(bp "$w git -C $r push origin feat")"
done
check "timeout with a substitution duration, unstamped repo denied" deny "$(bp 'timeout $(echo 5)s git push origin feat' "$p")"
check "sudo -u with a glued user, unstamped repo denied" deny "$(bp 'sudo -u $(id -un)x git push origin feat' "$p")"
check "env -C <unstamped repo> push denied" deny "$(bp "env -C $p git push origin feat")"
check "env -C <stamped repo> push silent" silent "$(bp "env -C $r git push origin feat")"
check "wrapped push in a cd chain denied" deny "$(bp "cd $p && timeout 5 git push origin feat")"
check "cd <stamped> && timeout push silent" silent "$(bp "cd $r && timeout 5 git push origin feat")"
check "nested bash -c push denied" deny "$(bp "bash -c \"bash -c 'git -C $p push origin feat'\"")"
check "wrapped push with a text-only exemption silent" silent "$(bp "timeout 5 git -C $p push --dry-run origin feat")"
# a passing record plus a literal path stays silent; so does the resolved simple assignment
check "literal cd with passing record silent" silent "$(bp "cd $r && git push origin feat")"
check "literal git -C with passing record silent" silent "$(bp "git -C $r push origin feat")"
check "unknown cd then literal absolute cd with record silent" silent "$(bp "cd \"\$W\" && cd $r && git push origin feat")"
check "unknown cd then git -C literal with record silent" silent "$(bp "cd \"\$W\" && git -C $r push origin feat")"
# item 3: a plain literal assignment earlier in the line is resolved
check "W=<repo>; cd \"\$W\" with record silent" silent "$(bp "W=$r && cd \"\$W\" && git push origin feat")"
check "W=<repo>; cd \$W with record silent" silent "$(bp "W=$r; cd \$W && git push origin feat")"
check "W=\"<repo>\"; cd \"\${W}\" with record silent" silent "$(bp "W=\"$r\"; cd \"\${W}\" && git push origin feat")"
check "W=<repo>; git -C \"\$W\" with record silent" silent "$(bp "W=$r; git -C \"\$W\" push origin feat")"
check "W=<dir>; cd \"\$W\"/sub resolved, record silent" silent "$(bp "W=$T; cd \"\$W\"/r && git push origin feat")"
check "W=<repo>; cd \"\$W\" && gh pr create with record silent" silent "$(bp "W=$r; cd \"\$W\" && gh pr create --title x")"
check "W=<repo>; (cd \"\$W\" && git push) with record silent" silent "$(bp "W=$r; (cd \"\$W\" && git push origin feat)")"
check "W=<repo>; cd; git push with semicolons resolves, record silent" silent "$(bp "W=$r; cd \"\$W\"; git push origin feat")"
check "W=<repo> eval resolves, record silent" silent "$(bp "W=$r; eval 'cd \$W && git push origin feat'")"
unk "backtick reassignment drops the stale recorded repo" "W=$r; W=\`echo $r\`; cd \"\$W\" && git push origin feat"
check "resolved W without record: normal deny" deny "$(bp "W=$p && cd \"\$W\" && git push origin feat")"
mode_warn; check "resolved W without record: normal warn" warn "$(bp "W=$p && cd \"\$W\" && git push origin feat")"; mode_deny
out="$(printf '%s' "$(bp "W=$p && cd \"\$W\" && git push origin feat")" | $gate | jq -r .hookSpecificOutput.permissionDecisionReason)"
case "$out" in *"no passing check record for $(git -C "$p" rev-parse HEAD | cut -c1-10)"*) ok "resolved W without record names the commit";; *) bad "resolved W message" "$out";; esac
check "W assigned a substitution is not resolved (denied)" deny "$(bp "W=\$(echo $r) && cd \"\$W\" && git push origin feat")"
check "reassigned W: last literal assignment wins" deny "$(bp "W=$r; W=$p; cd \"\$W\" && git push origin feat")"
check "assignment scoped by a subshell does not leak" deny "$(bp "(W=$r); cd \"\$W\" && git push origin feat")"
# false alarms: nothing is pushed, or the text is only data
check "W=/x; cd \"\$W\" && git status" silent "$(bp 'W=/x; cd "$W" && git status')"
check "cd \"\$W\" && git fetch" silent "$(bp 'cd "$W" && git fetch')"
check "cd \"\$W\" && git commit -m notes about git push" silent "$(bp 'cd "$W" && git commit -m "notes about git push"')"
check "git commit -m explain git push" silent "$(bp 'git commit -m "explain git push"')"
check "echo \"cd \$W && git push\"" silent "$(bp 'echo "cd $W && git push"')"
check "echo \"git push\"" silent "$(bp 'echo "git push"')"
check "echo 'gh pr create' after variable cd" silent "$(bp 'cd "$W" && echo "gh pr create"')"
check "gh pr view after variable cd" silent "$(bp 'cd "$W" && gh pr view 12')"
check "gh pr list after variable cd" silent "$(bp 'cd "$W" && gh pr list')"
check "bash -c with echo of git push" silent "$(bp "bash -c 'echo git push'")"
check "bash -c with variable cd and no push" silent "$(bp "bash -c 'cd \"\$W\" && git status'")"
check "grep for git push after variable cd" silent "$(bp 'cd "$W" && grep -r "git push" .')"
check "GIT_DIR=\$X git status" silent "$(bp 'GIT_DIR=$X git status')"
# literal --git-dir / --work-tree / GIT_DIR / GIT_WORK_TREE on a push: directory cannot be established (denied)
unk "literal --git-dir= on a push" "git --git-dir=$p/.git push origin feat"
unk "literal --work-tree on a push" "git --work-tree $p push origin feat"
unk "literal GIT_DIR= on a push" "GIT_DIR=$p/.git git push origin feat"
unk "literal GIT_WORK_TREE= on a push" "GIT_WORK_TREE=$p git push origin feat"
check "literal GIT_DIR= on git status stays silent" silent "$(bp "GIT_DIR=$p/.git git status")"
check "unknown dir, colon-form delete silent" silent "$(bp 'cd "$W" && git push origin :old')"
check "unknown -C, colon-form delete silent" silent "$(bp 'git -C "$W" push origin :old')"
# the variable is certain only after a standalone assignment that surely ran; each of these must not be silent
# ($r has a passing record, $p has none; the shell is in $p)
notsilent() { check "uncertain variable not resolved: $1" deny "$(bp "$2" "$p")"; mode_warn; check "uncertain variable not resolved (warn): $1" warn "$(bp "$2" "$p")"; mode_deny; }
notsilent 'prefix assignment on cd' "W=$r cd \"\$W\" && git push origin feat"
notsilent 'prefix assignment on git -C' "W=$r git -C \"\$W\" push origin feat"
notsilent 'assignment in a skipped if' "W=$p; if false; then W=$r; fi; cd \"\$W\" && git push origin feat"
notsilent 'after false &&' "false && W=$r; cd \"\$W\" && git push origin feat"
notsilent 'after true ||' "true || W=$r; cd \"\$W\" && git push origin feat"
notsilent 'after cmd && assignment' "true && W=$r; cd \"\$W\" && git push origin feat"
notsilent 'unset' "W=$r; unset W; cd \"\$W\"; git push origin feat"
notsilent 'read' "W=$r; read W; cd \"\$W\"; git push origin feat"
notsilent 'plus-equals' "W=$r; W+=/x; cd \"\$W\"; git push origin feat"
notsilent 'non-literal reassignment' "W=$r; W=\$(pwd); cd \"\$W\"; git push origin feat"
notsilent 'reference to another variable' "V=$r; W=\$V; cd \"\$W\"; git push origin feat"
notsilent 'export non-literal' "W=$r; export W=\$X; cd \"\$W\"; git push origin feat"
notsilent 'local' "W=$r; local W; cd \"\$W\"; git push origin feat"
notsilent 'declare' "W=$r; declare W=$p; cd \"\$W\"; git push origin feat"
notsilent 'typeset' "W=$r; typeset W; cd \"\$W\"; git push origin feat"
notsilent 'readonly' "W=$r; readonly W=$p; cd \"\$W\"; git push origin feat"
notsilent 'for loop' "W=$r; for W in $p; do cd \"\$W\"; git push origin feat; done"
notsilent 'assignment after a loop' "for x in 1; do W=$r; done; cd \"\$W\" && git push origin feat"
notsilent 'assignment in a function' "f() { W=$r; }; f; cd \"\$W\" && git push origin feat"
notsilent 'assignment in a subshell' "(W=$r); cd \"\$W\" && git push origin feat"
notsilent 'assignment in a case branch' "case x in x) W=$r;; esac; cd \"\$W\" && git push origin feat"
notsilent 'assignment in a pipeline' "W=$r | cat; cd \"\$W\" && git push origin feat"
notsilent 'background assignment' "W=$r & cd \"\$W\" && git push origin feat"
notsilent 'bash -c does not see an outer plain variable' "W=$r; bash -c 'cd \$W && git push origin feat'"
notsilent 'bash -c prefix assignment' "W=$r bash -c 'cd \$W && git push origin feat'"
notsilent 'eval after an unset' "W=$r; unset W; eval 'cd \$W && git push origin feat'"
notsilent 'gh pr create after prefix assignment' "W=$r cd \"\$W\" && gh pr create --title x"
notsilent 'gh pr create after skipped if' "W=$p; if false; then W=$r; fi; cd \"\$W\" && gh pr create --title x"
notsilent 'arithmetic command ((W=1))' "W=$r; ((W=1)); cd \"\$W\"; git push origin feat"
notsilent 'arithmetic command ((W++))' "W=$r; ((W++)); cd \"\$W\"; git push origin feat"
notsilent 'let W=1' "W=$r; let W=1; cd \"\$W\"; git push origin feat"
notsilent 'arithmetic expansion assigns' "W=$r; : \$((W=1)); cd \"\$W\"; git push origin feat"
check "plain: W=<repo> && cd && push resolves (record silent)" silent "$(bp "W=$r && cd \"\$W\" && git push origin feat" "$p")"
check "plain: W=<repo>; cd; push resolves (record silent)" silent "$(bp "W=$r; cd \"\$W\"; git push origin feat" "$p")"
out="$(printf '%s' "$(bp "bash -c 'cd \"\$W\" && gh pr create --title \"x'")" | $gate | jq -r .hookSpecificOutput.permissionDecisionReason)"
case "$out" in *"this gh pr create runs in"*) ok "unparseable body with gh pr create: message says gh pr create";; *) bad "kind in message" "$out";; esac
check "no cwd in payload: variable cd stays silent (malformed input)" silent "$(jq -n '{tool_name:"Bash",tool_input:{command:"cd \"$W\" && git push"}}')"

# --- broken checks file, escape, config as data ---
git -C "$T/broken" reset -q --hard HEAD; printf 'none\ntrue\n' > "$T/broken/.claude/git-checks"; git -C "$T/broken" commit -qam brk
check "DetectionError (broken checks file) denied in deny mode" deny "$(push 'git push origin feat' "$T/broken")"
out="$(printf '%s' "$(push 'git push origin feat' "$T/broken")" | $gate)"
jq -e '.hookSpecificOutput.permissionDecisionReason | test("could not be read") and test("none") and test("git-verify")' <<<"$out" >/dev/null && ok "broken-config message says it could not be read, includes the error and git-verify" || bad "broken-config message" "$out"
mode_warn
check "DetectionError (broken checks file) warns in warn mode" warn "$(push 'git push origin feat' "$T/broken")"
mode_deny
printf '{bad json' > "$T/broken/package.json"; rm "$T/broken/.claude/git-checks"; git -C "$T/broken" add -A; git -C "$T/broken" commit -qm pj
check "malformed package.json warns or denies, not silent" deny "$(push 'git push origin feat' "$T/broken")"
CLAUDE_CHECKS_GATE=off check "CLAUDE_CHECKS_GATE=off allows" silent "$(push)"
touch_marker="$T/pwned"
printf 'MODE=deny\ntouch %s\n$(touch %s)\n`touch %s`\n' "$touch_marker" "$touch_marker" "$touch_marker" > "$CLAUDE_CHECKS_GATE_CONF"
check "config with shell syntax still parsed as data" deny "$(push)"
[ ! -e "$touch_marker" ] && ok "config shell syntax executed nothing" || bad "config shell syntax executed something"
printf 'MODE=deny; touch %s\n' "$touch_marker" > "$CLAUDE_CHECKS_GATE_CONF"
check "MODE value with shell syntax is not deny" warn "$(push)"
[ ! -e "$touch_marker" ] && ok "MODE value with shell syntax executed nothing" || bad "MODE value executed something"
printf 'MODE=deny # reason\n' > "$CLAUDE_CHECKS_GATE_CONF"
check "trailing comment stripped: MODE=deny # reason is deny" deny "$(push)"
printf 'MODE = warn   # fine\nDENY_AFTER=2026-12-01 # soon\n' > "$CLAUDE_CHECKS_GATE_CONF"
CHECKS_GATE_TODAY=2026-12-05 check "trailing comment stripped from DENY_AFTER" deny "$(push)"
mode_deny

# --- shapes and robustness ---
out="$(printf '%s' "$(push)" | $gate)"
jq -e '.hookSpecificOutput.permissionDecisionReason | test("run-checks.sh") and test("CLAUDE_CHECKS_GATE=off")' <<<"$out" >/dev/null && ok "deny reason names run-checks.sh and the escape hatch" || bad "deny reason" "$out"
silentp() { local out; out="$(printf '%s' "$2" | $gate 2>&1)"; [ -z "$out" ] && ok "$1" || bad "$1" "$out"; }
silentp "empty stdin silent" ''
silentp "malformed JSON silent" '{not json'
silentp "non-object JSON silent" '[1,2]'
silentp "empty object silent" '{}'
silentp "non-string command silent" '{"tool_input":{"command":5}}'
mode_deny
check "unterminated quote holding a push is an unknown directory (denied)" deny "$(push "git push origin feat 'oops")"
silentp "unterminated quote without a push silent" "$(push "echo 'oops")"
nasty=$'git push origin feat; echo "q\\"x" \'s\'\n# nl'
check "deny with quotes and newlines in the command is valid JSON" deny "$(push "$nasty")"
mode_warn
check "warn with quotes and newlines in the command is valid JSON" warn "$(push "$nasty")"

# --- a line with too many commands is not walked ---
big="$(for k in $(seq 400); do printf 'git status; '; done)"
mode_deny
check "400 commands then a push is an unknown directory, denied" deny "$(bp "${big}git push origin feat" "$p")"
check "400 commands then gh pr create is denied" deny "$(bp "${big}gh pr create --title x" "$p")"
check "400 commands, no push, is silent" silent "$(bp "${big}git log" "$p")"
mode_warn
check "400 commands then a push warns in warn mode" warn "$(bp "${big}git push origin feat" "$p")"
mode_deny
check "the same push on an ordinary line is still judged by its repository" deny "$(push 'git status; git push origin feat')"

# --- never modifies a repository ---
before="$(snap)"
for i in 1 2 3; do printf '%s' "$(push)" | $gate >/dev/null; printf '%s' "$(bp 'gh pr create' "$T/stale")" | $gate >/dev/null; done
[ "$before" = "$(snap)" ] && ok "HEAD, index, work tree and stamps of every repo unchanged" || bad "repo state changed"
[ -z "$(find "$hooks" -name __pycache__ -o -name '*.pyc' | head -1)" ] && ok "no bytecode written next to the hooks" || bad "bytecode written"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
