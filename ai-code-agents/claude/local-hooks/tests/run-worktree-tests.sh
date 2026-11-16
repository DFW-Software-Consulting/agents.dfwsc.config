#!/usr/bin/env bash
# Payload-driven tests for worktree-gate.sh (and _git-cmd-scan.py).
# Builds throwaway repos under a temp dir and uses a temporary HOME so the real
# ~/.claude/worktree-gate.off is never read or touched.
# Usage: local-hooks/tests/run-worktree-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
# A temp root outside any git work tree for the gate's own TMPDIR (the scratch
# location may be inside one, which makes `mktemp -d` directories unknown).
safetmp=""
for c in /tmp /var/tmp /dev/shm "${XDG_RUNTIME_DIR:-/nonexistent}"; do
  if [ -d "$c" ] && ! git -C "$c" rev-parse --is-inside-work-tree >/dev/null 2>&1; then safetmp="$(mktemp -d "$c/wtg-tests.XXXXXX")"; break; fi
done
[ -n "$safetmp" ] || safetmp="$(mktemp -d)"
trap 'rm -rf "$HOME" "$safetmp"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_WORKTREE_GATE CLAUDE_WORKTREE_GATE_OFF_FILE
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
git config --global protocol.file.allow always
off="$HOME/.claude/worktree-gate.off"
gate="env TMPDIR=$safetmp bash $hooks/worktree-gate.sh"

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
check "cd \"\$DIR\" && git commit denied (directory unknown)" deny "$(bp 'cd "$DIR" && git commit -m x' "$primary")"
check "cd - && git commit denied (directory unknown)" deny "$(bp 'cd - && git commit -m x' "$primary")"
check "cd \$(mktemp -d) && git commit allowed (temporary directory)" allow "$(bp 'cd $(mktemp -d) && git commit -m x' "$primary")"
check "git -C \"\$D\" commit denied (directory unknown)" deny "$(bp 'git -C "$D" commit -m x' "$primary")"
check "git commit in non-repo allowed" allow "$(bp 'git commit -m x' "$plain")"
check "git commit in unborn repo allowed" allow "$(bp 'git commit -m x' "$unborn")"
check "git add in submodule of primary superproject denied" deny "$(bp 'git add -A' "$sub/vendor")"
check "relative cd resolved against cwd" deny "$(bp 'cd src && git add -A' "$primary")"
check "command without git word allowed" allow "$(bp 'ls -la' "$primary")"
check "heredoc body mentioning git commit allowed" allow "$(bp $'cat <<EOF\ngit commit -m x\nEOF' "$primary")"
check "unparseable command allowed" allow "$(bp "git commit -m 'oops" "$primary")"

# --- read-only forms ---
for c in 'git commit --help' 'git checkout -h' 'git --no-pager stash --help' 'git add -n .' 'git add --dry-run .' \
  'git rm -n x' 'git rm --dry-run x' 'git mv -n a b' 'git mv --dry-run a b' 'git clean -n' 'git clean --dry-run -d' \
  'git clean -nfd' 'git clean -n -f' 'git clean -fn' 'git commit --dry-run' 'git apply --check p.diff' \
  'git apply --stat p.diff' 'git apply --numstat p.diff' 'git apply --summary p.diff' 'git apply --index --check p.diff' \
  'GIT_DIR=x git commit --dry-run' 'GIT_WORK_TREE=x git add -n .' 'env GIT_DIR=x git commit --dry-run'; do
  check "allow: $c" allow "$(bp "$c" "$primary")"
done
for c in 'git clean -fd' 'git clean -f' 'git clean --force' 'git clean -d' 'git apply --index p.diff' 'git apply --cached p.diff' \
  'git apply -3 p.diff' 'git apply p.diff' 'git merge --no-commit x' 'git add .' 'git rm x' 'git mv a b' 'git commit -m x' \
  'git commit -am x' 'FOO=1 git clean -fd' 'GIT_DIR=x git commit -m x' 'GIT_WORK_TREE=x git add .' 'env GIT_DIR=x git commit -m x'; do
  check "deny: $c" deny "$(bp "$c" "$primary")"
done

# --- unknown directory, variables, wrapper bodies, temporary directories ---
P="$primary"; W="$wt"
reason_has() {  # NAME PAYLOAD REGEX
  local out; out="$(printf '%s' "$2" | $gate 2>&1)"
  if jq -e --arg re "$3" '.hookSpecificOutput.permissionDecisionReason | test($re)' <<<"$out" >/dev/null 2>&1; then
    pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (output: $out)"; fi
}
nest() { local c="$1" k; for k in $(seq "$2"); do c="$(printf '%s -c %q' "${3:-bash}" "$c")"; done; printf '%s' "$c"; }
# plain resolvable assignments are judged like a literal path
check "W=primary && cd \$W && commit denied" deny "$(bp "W=$P && cd \"\$W\" && git commit -m x" "$plain")"
check "W=primary; git -C \$W commit denied" deny "$(bp "W=$P; git -C \"\$W\" commit -m x" "$plain")"
check "W=worktree && cd \$W && commit allowed" allow "$(bp "W=$W && cd \"\$W\" && git commit -m x" "$primary")"
check "W=worktree; git -C \$W commit allowed" allow "$(bp "W=$W; git -C \"\$W\" commit -m x" "$primary")"
check "export W=primary; cd \$W; add denied" deny "$(bp "export W=$P; cd \"\$W\"; git add ." "$plain")"
check "W=primary then relative cd below it denied" deny "$(bp "W=$P && cd \"\$W\" && cd src && git add ." "$plain")"
reason_has "denial for an assigned primary path names the root" "$(bp "W=$P; git -C \"\$W\" commit -m x" "$plain")" "primary checkout of"
# unknown directory: checkout-changing commands denied, with the new message
check "cd \$ENV_VAR && commit denied" deny "$(bp 'cd "$ENV_VAR" && git commit -m x' "$plain")"
check "git -C \$W (unset) commit denied" deny "$(bp 'git -C "$W2" commit -m x' "$wt")"
check "unknown directory from a worktree cwd: git add denied" deny "$(bp 'cd "$X" && git add -A' "$wt")"
check "(cd \$W && commit) denied" deny "$(bp '(cd "$W2" && git commit -m x)' "$plain")"
check "pushd \$W && commit denied" deny "$(bp 'pushd "$W2" >/dev/null && git commit -m x' "$plain")"
check "popd && commit denied" deny "$(bp 'popd && git commit -m x' "$plain")"
check "cd \$(git rev-parse --show-toplevel) && commit denied" deny "$(bp 'cd $(git rev-parse --show-toplevel) && git commit -m x' "$plain")"
check "git -C \$(...) unquoted commit denied" deny "$(bp 'git -C $(git rev-parse --show-toplevel) commit -m x' "$plain")"
check "GIT_DIR=\$W commit denied" deny "$(bp 'GIT_DIR="$W2" git commit -m x' "$plain")"
check "--git-dir=\$W commit denied" deny "$(bp 'git --git-dir="$W2" commit -m x' "$plain")"
check "doubtful assignment is unknown: true && W=x; cd \$W denied" deny "$(bp "true && W=$wt; cd \"\$W\" && git commit -m x" "$plain")"
check "conditional assignment is unknown denied" deny "$(bp "if true; then W=$wt; fi; cd \"\$W\" && git commit -m x" "$plain")"
check "backtick reassignment drops the stale linked-worktree value: denied" deny "$(bp "W=$wt; W=\`echo $wt\`; cd \"\$W\" && git commit -m x" "$plain")"
check "a directory is nonexistent so its nearest existing ancestor is judged: mkdir t && cd t && commit in primary denied" deny "$(bp 'mkdir t && cd t && git commit -m x' "$primary")"
check "cd into a not yet existing subdirectory of primary denied" deny "$(bp "cd $P/newdir/deeper && git commit -m x" "$plain")"
check "git -C a not yet existing path under primary denied" deny "$(bp "git -C $P/nothere commit -m x" "$plain")"
check "mkdir t && cd t && commit in a worktree allowed" allow "$(bp 'mkdir t && cd t && git commit -m x' "$wt")"
check "unknown directory then literal cd into a worktree allowed" allow "$(bp "cd \"\$X\" && cd $wt && git commit -m x" "$primary")"
reason_has "unknown-directory denial says it could not tell the checkout" "$(bp 'cd "$X" && git commit -m x' "$plain")" "could not tell which checkout git commit runs in"
reason_has "unknown-directory denial asks for a literal directory" "$(bp 'cd "$X" && git commit -m x' "$plain")" "Write the directory literally"
reason_has "unknown-directory denial names the escape hatch" "$(bp 'cd "$X" && git commit -m x' "$plain")" "CLAUDE_WORKTREE_GATE=off"
# explicit git directories are judged by their work tree
check "GIT_DIR=x commit (a directory that is not a repository) denied" deny "$(bp 'GIT_DIR=x git commit -m x' "$primary")"
check "--git-dir=x commit (a directory that is not a repository) denied" deny "$(bp 'git --git-dir=x commit -m x' "$primary")"
check "GIT_DIR=primary/.git commit denied" deny "$(bp "GIT_DIR=$P/.git git commit -m x" "$plain")"
check "--git-dir=primary/.git --work-tree=primary reset --hard denied" deny "$(bp "git --git-dir=$P/.git --work-tree=$P reset --hard" "$plain")"
check "export GIT_DIR=primary/.git; commit denied" deny "$(bp "export GIT_DIR=$P/.git; git commit -m x" "$plain")"
check "GIT_WORK_TREE=primary checkout . denied" deny "$(bp "GIT_WORK_TREE=$P git checkout ." "$plain")"
check "GIT_DIR=primary/.git GIT_WORK_TREE=worktree commit denied (the primary repository changes)" deny "$(bp "GIT_DIR=$P/.git GIT_WORK_TREE=$W git commit -m x" "$plain")"
check "GIT_DIR=linked worktree's git dir commit allowed" allow "$(bp "GIT_DIR=$P/.git/worktrees/wt git commit -m x" "$plain")"
check "--git-dir=linked worktree's git dir --work-tree=worktree commit allowed" allow "$(bp "git --git-dir=$P/.git/worktrees/wt --work-tree=$W commit -m x" "$plain")"
check "GIT_WORK_TREE=worktree add allowed" allow "$(bp "GIT_WORK_TREE=$W git add ." "$plain")"
check "GIT_DIR=primary/.git status allowed (read-only)" allow "$(bp "GIT_DIR=$P/.git git status" "$plain")"
check "GIT_DIR=\$V export then commit denied (unknown)" deny "$(bp 'export GIT_DIR="$V"; git commit -m x' "$plain")"
# env -C
check "env -C primary commit denied" deny "$(bp "env -C $P git commit -m x" "$plain")"
check "env -C worktree commit allowed" allow "$(bp "env -C $W git commit -m x" "$primary")"
check "env -C \$W commit denied" deny "$(bp 'env -C "$W2" git commit -m x' "$plain")"
check "env FOO=1 -C primary commit denied" deny "$(bp "env FOO=1 -C $P git commit -m x" "$plain")"
check "env -C \$W status allowed (read-only)" allow "$(bp 'env -C "$W2" git status' "$plain")"
# env -C carries into a body; builtin and command cd
check "env -C primary bash -c commit denied" deny "$(bp "env -C $P bash -c 'git commit -m x'" "$plain")"
check "env -C primary sh -c add denied" deny "$(bp "env -C $P sh -c 'git add -A'" "$plain")"
check "env -C worktree bash -c commit allowed" allow "$(bp "env -C $W bash -c 'git commit -m x'" "$primary")"
check "env -C primary eval commit denied" deny "$(bp "env -C $P eval 'git commit -m x'" "$plain")"
check "builtin cd primary && commit denied" deny "$(bp "builtin cd $P && git commit -m x" "$plain")"
check "command cd primary && commit denied" deny "$(bp "command cd $P && git commit -m x" "$plain")"
check "builtin cd worktree && commit allowed" allow "$(bp "builtin cd $W && git commit -m x" "$primary")"
check "timeout 5 git commit in primary denied" deny "$(bp 'timeout 5 git commit -m x' "$primary")"
check "env -S 'git commit' in primary denied" deny "$(bp "env -S 'git commit -m x'" "$primary")"
# wrapper bodies
check "bash -c commit in a primary cwd denied" deny "$(bp "bash -c 'git commit -m x'" "$primary")"
check "bash -c commit in a worktree cwd allowed" allow "$(bp "bash -c 'git commit -m x'" "$wt")"
check "bash -c cd primary && commit denied" deny "$(bp "bash -c 'cd $P && git commit -m x'" "$plain")"
check "bash -c cd worktree && commit allowed" allow "$(bp "bash -c 'cd $W && git commit -m x'" "$primary")"
check "bash -c cd \$W && commit denied" deny "$(bp "bash -c 'cd \"\$W2\" && git commit -m x'" "$plain")"
check "sh -c commit in a primary cwd denied" deny "$(bp "sh -c 'git add -A'" "$primary")"
check "eval commit in a primary cwd denied" deny "$(bp "eval 'git commit -m x'" "$primary")"
check "eval cd worktree && commit allowed" allow "$(bp "eval 'cd $W && git commit -m x'" "$primary")"
check "eval uses an earlier assignment (primary) denied" deny "$(bp "W=$P; eval 'cd \"\$W\" && git commit -m x'" "$plain")"
check "bash -c cd inside does not leak out: later commit judged in the old directory" deny "$(bp "bash -c 'cd $W' && git commit -m x" "$primary")"
check "three levels deep commit in a primary cwd denied" deny "$(bp "$(nest 'git commit -m x' 3)" "$primary")"
check "three levels deep commit in a worktree cwd allowed" allow "$(bp "$(nest 'git commit -m x' 3 sh)" "$wt")"
check "three levels deep cd primary then commit denied" deny "$(bp "$(nest "cd $P && git commit -m x" 3)" "$plain")"
check "four levels deep is not followed (documented limit)" allow "$(bp "$(nest 'git commit -m x' 4)" "$primary")"
check "bash script file allowed" allow "$(bp 'bash ./make.sh && git status' "$primary")"
# escaped quotes in followed bodies (double-quoted at each level)
dq() { local t="${1//\\/\\\\}"; t="${t//\"/\\\"}"; t="${t//\$/\\\$}"; printf 'bash -c "%s"' "$t"; }
c1="$(dq "cd \"$P\" && git commit -m x")"; c2="$(dq "$c1")"; c3="$(dq "$c2")"
check "bash -c \"cd \\\"P\\\" && commit\" from a worktree cwd denied" deny "$(bp "$c1" "$wt")"
check "two levels of escaped quotes denied" deny "$(bp "$c2" "$wt")"
check "three levels of escaped quotes denied" deny "$(bp "$c3" "$wt")"
check "escaped quotes with a worktree directory allowed" allow "$(bp "$(dq "cd \"$W\" && git commit -m x")" "$primary")"
check "escaped quotes, three levels, a worktree directory allowed" allow "$(bp "$(dq "$(dq "$(dq "cd \"$W\" && git commit -m x")")")" "$primary")"
check "escaped dollar in a body is not a variable of the outer line" deny "$(bp "$(dq 'cd "$X" && git commit -m x')" "$wt")"
check "unparseable body holding a commit denied" deny "$(bp "bash -c \"git commit -m 'oops\"" "$wt")"
check "unparseable nested body holding a commit denied" deny "$(bp "$(dq "bash -c \"git add 'oops\"")" "$wt")"
silent "unparseable body with no git command is silent" "$(bp "bash -c \"echo 'oops\"" "$primary")"
silent "commit message that mentions a commit in a body is silent (read-only line)" "$(bp "git log --grep=\"bash -c 'git commit'\"" "$primary")"
check "commit message that mentions a wrapper is data" allow "$(bp "git commit --dry-run -m \"bash -c 'cd $P && git commit'\"" "$primary")"
# temporary directories: only a bare mktemp -d, with TMPDIR untouched and a safe temp root
# temporary directories
check "T=\$(mktemp -d) && cd \$T && commit allowed" allow "$(bp 'T=$(mktemp -d) && cd "$T" && git init -q && git commit -m x' "$primary")"
check "T=\$(mktemp -d); git -C \$T commit allowed" allow "$(bp 'T=$(mktemp -d); git -C "$T" commit -m x' "$primary")"
check "cd \"\$(mktemp -d)\" && commit allowed" allow "$(bp 'cd "$(mktemp -d)" && git commit -m x' "$primary")"
check "git -C \"\$(mktemp -d)\" add allowed" allow "$(bp 'git -C "$(mktemp -d)" add -A' "$primary")"
check "mktemp -d -q allowed" allow "$(bp 'T=$(mktemp -q -d) && cd "$T" && git add .' "$primary")"
for f in 'cd $(mktemp -d -p @P@)' 'T=$(mktemp -d --tmpdir=@P@); cd "$T"' 'T=$(mktemp -d @P@/t.XXXX); cd "$T"' \
  'T=$(mktemp -d t.XXXX); cd "$T"' 'T=$(mktemp -d -p .); cd "$T"' 'T=$(mktemp -d -p src); cd "$T"' 'T=$(mktemp -d -p "$PWD"); cd "$T"' \
  'TMPDIR=@P@; T=$(mktemp -d); cd "$T"' 'export TMPDIR=@P@; cd $(mktemp -d)' 'TMPDIR=@P@ bash -c '"'"'cd $(mktemp -d) && git add .'"'"'' \
  'T=$(mktemp -u -d -p @P@); cd "$T"' 'T=$(mktemp -d -t x); cd "$T"' 'T=$(mktemp -d --suffix=.x); cd "$T"' \
  'cd @P@; T=$(mktemp -d t.XXXX); cd "$T"' 'cd @P@ && T=$(mktemp -d t.XXXX) && cd "$T"' 'T=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"); cd "$T"' \
  'TMPDIR=@P@ env sh -c '"'"'cd $(mktemp -d) && git add .'"'"'' 'export TMPDIR=@P@; eval '"'"'cd $(mktemp -d) && git add .'"'"''; do
  c="${f//@P@/$P}"; case "$c" in *'git add .'*) ;; *) c="$c && git add ." ;; esac
  check "mktemp abuse denied: $f" deny "$(bp "$c" "$primary")"
done
silent_tmp() {  # NAME TMPDIR_FOR_GATE PAYLOAD: exits 0, no output
  local out; out="$(printf '%s' "$3" | TMPDIR="$2" bash "$hooks/worktree-gate.sh" 2>&1)"
  if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (output: $out)"; fi
}
deny_tmp() {
  local out; out="$(printf '%s' "$3" | TMPDIR="$2" bash "$hooks/worktree-gate.sh" 2>&1)"
  if grep -q '"permissionDecision": *"deny"' <<<"$out"; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (output: $out)"; fi
}
deny_tmp "temp root inside a git work tree: bare mktemp -d is unknown, denied" "$primary/src" "$(bp 'T=$(mktemp -d) && cd "$T" && git add .' "$primary")"
silent_tmp "temp root outside any work tree: bare mktemp -d allowed" "$safetmp" "$(bp 'T=$(mktemp -d) && cd "$T" && git add .' "$primary")"
check "mktemp backticks allowed" allow "$(bp 'T=`mktemp -d`; cd "$T" && git add .' "$primary")"
check "temporary directory, relative cd below it allowed" allow "$(bp 'T=$(mktemp -d) && cd "$T" && mkdir a && cd a && git add .' "$primary")"
check "git -C \$T/sub below a temporary directory allowed" allow "$(bp 'T=$(mktemp -d); git -C "$T/sub" add .' "$primary")"
check "export T=\$(mktemp -d) allowed" allow "$(bp 'export T=$(mktemp -d); cd "$T" && git add .' "$primary")"
check "quoted assignment T=\"\$(mktemp -d)\" allowed" allow "$(bp 'T="$(mktemp -d)"; cd "$T" && git add .' "$primary")"
check "eval in a temporary directory allowed" allow "$(bp 'T=$(mktemp -d); eval "cd $T && git add ."' "$primary")"
check "bash -c cd mktemp -d && commit allowed" allow "$(bp "bash -c 'cd \"\$(mktemp -d)\" && git commit -m x'" "$primary")"
check "temporary directory then literal cd to primary denied" deny "$(bp "T=\$(mktemp -d) && cd \"\$T\" && cd $P && git commit -m x" "$plain")"
check "temporary directory reassigned from a variable denied" deny "$(bp 'T=$(mktemp -d); T=$X; cd "$T" && git commit -m x' "$primary")"
check "mktemp without -d (a file) denied" deny "$(bp 'T=$(mktemp); cd "$T" && git commit -m x' "$primary")"
check "other variable than the temporary one denied" deny "$(bp 'T=$(mktemp -d); cd "$U" && git commit -m x' "$primary")"
check "mktemp assignment after && following a command is doubtful, denied" deny "$(bp 'true && T=$(mktemp -d) && cd "$T" && git commit -m x' "$primary")"
check "temporary directory scoped by a subshell: commit after it judged in cwd" deny "$(bp '(cd "$(mktemp -d)" && git init -q); git commit -m x' "$primary")"
check "mktemp -d .. escape denied" deny "$(bp 'T=$(mktemp -d); cd "$T/../x" && git commit -m x' "$primary")"
# nothing on the line may redirect a mktemp path
for f in 'T=$(mktemp -d) && ln -s @P@ "$T/l" && cd "$T/l" && git commit -am x' \
  'T=$(mktemp -d); rmdir "$T" && ln -s @P@ "$T" && cd "$T" && git commit -am x' \
  ': ${TMPDIR:=@P@}; cd $(mktemp -d) && git commit -am x' 'T=$(mktemp -d) && mv @P@ "$T/l" && cd "$T/l" && git commit -am x' \
  'T=$(mktemp -d) && rm -rf "$T" && cd "$T" && git commit -am x' 'T=$(mktemp -d) && mount --bind @P@ "$T" && cd "$T" && git commit -am x' \
  "bash -c 'T=\$(mktemp -d); ln -s @P@ \"\$T/l\"; cd \"\$T/l\" && git commit -am x'"; do
  check "mktemp redirect denied: $f" deny "$(bp "${f//@P@/$P}" "$plain")"
done
check "git clone into a mktemp directory then commit allowed" allow "$(bp 'T=$(mktemp -d) && git clone https://example.invalid/r.git "$T/c" && cd "$T/c" && git commit -m x' "$primary")"
mkdir -p "$T/stray/.git" "$T/stray/tmp"
silent_tmp "stray empty .git above the temp root: plain mktemp allowed" "$T/stray/tmp" "$(bp 'T=$(mktemp -d) && cd "$T" && git init -q && git add . && git commit -m x' "$primary")"
# read-only commands with an unknown directory stay silent
for c in 'cd "$X" && git status' 'git -C "$X" log --oneline' 'git -C "$X" stash list' 'git -C "$X" add -n .' \
  'cd "$X" && git diff' 'cd - && git fetch origin' 'git -C "$X" commit --dry-run' 'git -C "$X" clean -n' \
  "bash -c 'cd \"\$X\" && git status'" 'GIT_DIR="$X" git log' 'env -C "$X" git branch' 'git -C "$X" commit --help' 'cd "$X" && git pull --ff-only'; do
  silent "silent: $c" "$(bp "$c" "$primary")"
done
silent "am --show-current-patch with an unknown directory is silent" "$(bp 'cd "$X" && git am --show-current-patch' "$primary")"
silent "rebase --show-current-patch with an unknown directory is silent" "$(bp 'git -C "$X" rebase --show-current-patch=diff' "$primary")"
check "am --continue with an unknown directory denied" deny "$(bp 'cd "$X" && git am --continue' "$primary")"
# a line over the analysis budget: no mutating command seen means silent, a mutating one is unknown
big="$(for k in $(seq 400); do printf 'git status; '; done)"
silent "400 read-only git commands are silent" "$(bp "${big}git log" "$primary")"
check "400 git commands then a commit is denied (too many commands to analyse)" deny "$(bp "${big}git commit -m x" "$wt")"
reason_has "the over-budget denial says why" "$(bp "${big}git commit -m x" "$wt")" "too many commands to analyse"
# text as data stays silent
silent "echo of a git commit after an unknown cd is silent" "$(bp 'cd "$X" && echo "git commit -m x"' "$primary")"
silent "heredoc body after an unknown cd is silent" "$(bp $'cd "$X" && cat <<EOF\ngit commit -m x\nEOF' "$primary")"
silent "bash -c echo of a git commit is silent" "$(bp "bash -c 'cd \"\$X\" && echo \"git commit -m x\"'" "$primary")"
silent "grep for git stash after an unknown cd is silent" "$(bp "cd \"\$X\" && grep -r 'git stash' ." "$primary")"
silent "payload without a cwd and a plain commit is silent (fail open)" "$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -m x"}}')"
silent "unparseable wrapper body is silent" "$(bp "bash -c 'git commit -m \\'oops'" "$primary")"
# several commands on one line: any denial wins
check "allowed worktree command then unknown-directory commit denied" deny "$(bp "git -C $wt commit -m a && cd \"\$X\" && git commit -m b" "$primary")"
check "temporary and worktree commands only allowed" allow "$(bp "git -C $wt commit -m a && git -C \"\$(mktemp -d)\" commit -m b" "$primary")"

# --- escape hatch ---
edit_primary="$(fp "$primary/src/a.txt")"
touch "$off"
check "fresh off-file allows" allow "$edit_primary"
check "fresh off-file allows Bash" allow "$(bp 'git commit -m x' "$primary")"
check "fresh off-file allows an unknown-directory commit" allow "$(bp 'cd "$X" && git commit -m x' "$primary")"
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
