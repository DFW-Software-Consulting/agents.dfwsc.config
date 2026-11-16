#!/usr/bin/env bash
# Payload-driven tests for git-guard.sh (and the git-command parts of _git-cmd-scan.py).
# Builds throwaway repos, each with a local bare repository as `origin`, under a
# temp dir, and uses a temporary HOME so the real ~/.claude/git-guard.off is never read.
# Usage: local-hooks/tests/run-git-guard-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_GIT_GUARD CLAUDE_GIT_GUARD_OFF_FILE
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
off="$HOME/.claude/git-guard.off"
gate="bash $hooks/git-guard.sh"

pass=0; fail=0
check() {
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | $gate 2>&1)"; rc=$?
  if grep -q '"permissionDecision": *"deny"' <<<"$out" && jq -e '(.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.hookEventName=="PreToolUse" and (.hookSpecificOutput.permissionDecisionReason|type=="string")' <<<"$out" >/dev/null 2>&1; then got=deny; else got=allow; fi
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
reason_has() {  # NAME PAYLOAD REGEX
  local out; out="$(printf '%s' "$2" | $gate 2>&1)"
  if jq -e --arg re "$3" '.hookSpecificOutput.permissionDecisionReason | test($re)' <<<"$out" >/dev/null 2>&1; then
    pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (output: $out)"; fi
}

# --- fixtures ---
T="$(mktemp -d "$HOME/t.XXXXXX")"
# mkrepo NAME DEFAULT: repo on DEFAULT with a bare `origin`, origin/HEAD set, a feature branch,
# a tag v1.0.0 and a branch old-branch.
mkrepo() {
  local n="$1" def="$2"
  git init -q --bare -b "$def" "$T/$n.git"
  git init -q -b "$def" "$T/$n"
  echo a > "$T/$n/f"; git -C "$T/$n" add -A; git -C "$T/$n" commit -qm init
  git -C "$T/$n" remote add origin "$T/$n.git"
  git -C "$T/$n" push -q origin "$def"
  git -C "$T/$n" fetch -q origin
  git -C "$T/$n" remote set-head origin "$def" >/dev/null
  git -C "$T/$n" branch feature; git -C "$T/$n" branch old-branch; git -C "$T/$n" branch force-fix
  git -C "$T/$n" tag v1.0.0
}
mkrepo r main; mkrepo rm master; mkrepo rt trunk
git init -q "$T/noremote"; echo a > "$T/noremote/f"; git -C "$T/noremote" add -A; git -C "$T/noremote" commit -qm i
mkrepo ru main                       # origin/HEAD unset, main ref present
git -C "$T/ru" symbolic-ref --delete refs/remotes/origin/HEAD
mkrepo rs main                       # second remote named upstream, default master there
git init -q --bare -b master "$T/up.git"
git -C "$T/rs" remote add upstream "$T/up.git"
git -C "$T/rs" push -q upstream main:master; git -C "$T/rs" fetch -q upstream
git -C "$T/rs" remote set-head upstream master >/dev/null
elsewhere="$T/elsewhere"; mkdir "$elsewhere"

bp() { jq -n --arg c "$1" --arg d "${2:-$T/r}" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
on_feature() { git -C "$1" checkout -q feature; }
on_main() { git -C "$1" checkout -q "${2:-main}"; }

snap() { for d in r rm rt noremote ru rs; do echo "$d $(git -C "$T/$d" rev-parse HEAD) $(git -C "$T/$d" symbolic-ref -q HEAD) $(git -C "$T/$d" status --porcelain | md5sum) $(git -C "$T/$d" ls-files -s | md5sum)"; done; }
before="$(snap)"

# --- bypass ---
check "commit --no-verify denied" deny "$(bp 'git commit --no-verify -m x')"
check "commit -n denied" deny "$(bp 'git commit -n -m x')"
check "commit -nm denied" deny "$(bp 'git commit -nm x')"
check "commit -anm denied" deny "$(bp 'git commit -anm x')"
check "push --no-verify denied" deny "$(bp 'git push --no-verify origin feature')"
check "merge --no-verify denied" deny "$(bp 'git merge --no-verify feature')"
check "rebase --no-verify denied" deny "$(bp 'git rebase --no-verify main')"
check "am --no-verify denied" deny "$(bp 'git am --no-verify x.patch')"
check "HUSKY=0 commit denied" deny "$(bp 'HUSKY=0 git commit -m x')"
check "HUSKY_SKIP_HOOKS=1 commit denied" deny "$(bp 'HUSKY_SKIP_HOOKS=1 git commit -m x')"
check "SKIP=lint commit denied" deny "$(bp 'SKIP=lint git commit -m x')"
check "SKIP=x push denied" deny "$(bp 'SKIP=x git push origin feature')"
check "-c core.hooksPath commit denied" deny "$(bp 'git -c core.hooksPath=/dev/null commit -m x')"
check "-c core.hooksPath push denied" deny "$(bp 'git -c core.hooksPath=/dev/null push origin feature')"
check "push -n allowed" allow "$(bp 'git push -n origin feature')"
check "add -n allowed" allow "$(bp 'git add -n .')"
check "clean -n allowed" allow "$(bp 'git clean -n')"
check "commit -m mentioning --no-verify allowed" allow "$(bp 'git commit -m "docs: mention --no-verify"')"
check "commit -mn style value allowed" allow "$(bp 'git commit -mn')"
check "echo of commit --no-verify allowed" allow "$(bp 'echo "git commit --no-verify"')"
check "git log --grep=--no-verify allowed" allow "$(bp 'git log --grep=--no-verify')"
check "plain commit allowed" allow "$(bp 'git commit -m x')"
check "HUSKY=1 commit allowed" allow "$(bp 'HUSKY=1 git commit -m x')"
check "-c user.name commit allowed" allow "$(bp 'git -c user.name=x commit -m y')"
check "HUSKY=0 on a non-commit git command allowed" allow "$(bp 'HUSKY=0 git status')"

# --- force ---
check "push --force denied" deny "$(bp 'git push --force origin feature')"
check "push -f denied" deny "$(bp 'git push -f origin feature')"
check "push -fu denied" deny "$(bp 'git push -fu origin x')"
check "push --force-with-lease denied" deny "$(bp 'git push --force-with-lease origin feature')"
check "push --force-with-lease=x:abc denied" deny "$(bp 'git push --force-with-lease=x:abc origin feature')"
check "push --force-if-includes denied" deny "$(bp 'git push --force-if-includes origin feature')"
check "push + refspec denied" deny "$(bp 'git push origin +feature')"
check "push +refs/heads refspec denied" deny "$(bp 'git push origin +refs/heads/a:refs/heads/a')"
check "push -u origin feature allowed" allow "$(bp 'git push -u origin feature')"
check "branch named force-fix allowed" allow "$(bp 'git push origin force-fix')"
check "push -f dry run allowed" allow "$(bp 'git push -f -n origin feature')"
reason_has "force denial names the rule" "$(bp 'git push -f origin feature')" 'force-push'

# --- default branch (main) ---
check "push origin main denied" deny "$(bp 'git push origin main')"
check "push origin HEAD:main denied" deny "$(bp 'git push origin HEAD:main')"
check "push origin feature:main denied" deny "$(bp 'git push origin feature:main')"
check "push origin refs/heads/main denied" deny "$(bp 'git push origin refs/heads/main')"
check "push origin :main denied" deny "$(bp 'git push origin :main')"
check "push --delete origin main denied" deny "$(bp 'git push --delete origin main')"
check "push origin --delete main denied" deny "$(bp 'git push origin --delete main')"
check "push --all denied" deny "$(bp 'git push --all origin')"
check "push --mirror denied" deny "$(bp 'git push --mirror origin')"
check "bare push on main denied" deny "$(bp 'git push')"
check "push -u origin main denied" deny "$(bp 'git push -u origin main')"
check "push origin HEAD on main denied" deny "$(bp 'git push origin HEAD')"
check "push origin feature allowed" allow "$(bp 'git push origin feature')"
check "push --tags on main allowed" allow "$(bp 'git push --tags')"
check "push origin v1.0.0 (a tag) allowed" allow "$(bp 'git push origin v1.0.0')"
check "push origin refs/tags/v1.0.0 allowed" allow "$(bp 'git push origin refs/tags/v1.0.0')"
check "push --delete old-branch allowed" allow "$(bp 'git push origin --delete old-branch')"
check "push --dry-run origin main allowed" allow "$(bp 'git push --dry-run origin main')"
check "push -n origin main allowed" allow "$(bp 'git push -n origin main')"
on_feature "$T/r"
check "bare push on feature branch allowed" allow "$(bp 'git push')"
check "push origin HEAD on feature branch allowed" allow "$(bp 'git push origin HEAD')"
check "push -u origin HEAD on feature branch allowed" allow "$(bp 'git push -u origin HEAD')"
check "push origin main still denied on feature branch" deny "$(bp 'git push origin main')"
on_main "$T/r"
reason_has "default-branch denial names rule and PR route" "$(bp 'git push origin main')" 'default-branch-push.*pull request'
reason_has "denial names the escape hatch" "$(bp 'git push origin main')" 'git-guard\.off.*CLAUDE_GIT_GUARD=off'

# master / trunk / unset / no remote / second remote
check "master default: push origin master denied" deny "$(bp 'git push origin master' "$T/rm")"
check "master default: push origin main allowed" allow "$(bp 'git push origin main' "$T/rm")"
check "master default: bare push on master denied" deny "$(bp 'git push' "$T/rm")"
check "trunk default: push origin trunk denied" deny "$(bp 'git push origin trunk' "$T/rt")"
check "trunk default: push origin main allowed" allow "$(bp 'git push origin main' "$T/rt")"
check "trunk default: bare push on trunk denied" deny "$(bp 'git push' "$T/rt")"
check "origin/HEAD unset, main ref present: push origin main denied" deny "$(bp 'git push origin main' "$T/ru")"
check "origin/HEAD unset: bare push on main denied" deny "$(bp 'git push' "$T/ru")"
check "no remote: push origin main allowed" allow "$(bp 'git push origin main' "$T/noremote")"
check "no remote: bare push allowed" allow "$(bp 'git push' "$T/noremote")"
check "upstream remote (default master): push upstream master denied" deny "$(bp 'git push upstream master' "$T/rs")"
check "upstream remote (default master): push upstream main allowed" allow "$(bp 'git push upstream main' "$T/rs")"
check "origin remote of same repo: push origin main denied" deny "$(bp 'git push origin main' "$T/rs")"

# --- directory ---
check "-C <repo> push origin main from other cwd denied" deny "$(bp "git -C $T/r push origin main" "$elsewhere")"
check "cd <repo> && push origin main denied" deny "$(bp "cd $T/r && git push origin main" "$elsewhere")"
check "cd \$X && push origin main allowed (undeterminable)" allow "$(bp 'cd "$X" && git push origin main' "$elsewhere")"
check "-C \$X push origin main allowed (undeterminable)" allow "$(bp 'git -C "$X" push origin main' "$elsewhere")"
check "push origin main from non-repo cwd allowed" allow "$(bp 'git push origin main' "$elsewhere")"
check "cwd missing allowed" allow "$(bp 'git push origin main' "$T/does-not-exist")"
check "-C trunk repo judged by that repo" deny "$(bp "git -C $T/rt push origin trunk" "$T/r")"

# --- scope ---
check "denied for a subagent too" deny "$(bp 'git push origin main' | jq '.agent_id="a1"')"
check "allowed for a subagent too" allow "$(bp 'git push origin feature' | jq '.agent_id="a1"')"
check "several git commands, only last denied" deny "$(bp 'git status && git fetch origin && git push origin main')"
check "several git commands, none denied" allow "$(bp 'git status && git fetch origin && git push origin feature')"
check "denied command inside subshell found" deny "$(bp '(git push origin main)')"
pad="$(head -c 20000 /dev/zero | tr '\0' 'a')"
check "20 KB command, denied push at the end" deny "$(bp "echo $pad && git push origin main")"
check "20 KB command, nothing denied" allow "$(bp "echo $pad && git push origin feature")"
check "non-git command allowed" allow "$(bp 'ls -la')"
check "git word only inside quotes allowed" allow "$(bp "echo 'git push origin main'")"
check "heredoc body allowed" allow "$(bp $'cat <<EOF\ngit push --force origin main\nEOF')"

# --- review fixes: abbreviated long options ---
check "push --force-w denied" deny "$(bp 'git push --force-w origin feature')"
check "push --forc denied" deny "$(bp 'git push --forc origin feature')"
check "push --force-with-l=x denied" deny "$(bp 'git push --force-with-l=x origin feature')"
check "push --force-i denied" deny "$(bp 'git push --force-i origin feature')"
check "commit --no-ver denied" deny "$(bp 'git commit --no-ver -m x')"
check "push --no-ver denied" deny "$(bp 'git push --no-ver origin feature')"
check "push --mirr denied" deny "$(bp 'git push --mirr origin')"
check "push --al denied" deny "$(bp 'git push --al origin')"
check "commit --no-edit allowed" allow "$(bp 'git commit --amend --no-edit')"
check "push --follow-tags (feature) allowed" allow "$(bp 'git push --follow-tags origin feature')"
check "push --no-tags-style: --no-thin allowed" allow "$(bp 'git push --no-thin origin feature')"
check "push --atomic origin feat/x allowed" allow "$(bp 'git push --atomic origin feat/x')"
check "push --no-force-with-lease allowed" allow "$(bp 'git push --no-force-with-lease origin feature')"
check "push --dry origin main allowed (abbreviated dry run)" allow "$(bp 'git push --dry origin main')"
check "merge --no-edit allowed" allow "$(bp 'git merge --no-edit feature')"
check "rebase --no-ff allowed" allow "$(bp 'git rebase --no-ff main')"

# --- flag rules do not depend on the directory ---
check "cd missing-dir && commit -n denied" deny "$(bp "cd $T/newdir && git commit -n -m x" "$elsewhere")"
check "cd \$X && commit -n denied" deny "$(bp 'cd "$X" && git commit -n -m x' "$elsewhere")"
check "cd \$X && push -f denied" deny "$(bp 'cd "$X" && git push -f' "$elsewhere")"
check "-C \$X push --force denied" deny "$(bp 'git -C "$X" push --force origin x' "$elsewhere")"
check "cd missing-dir && push --no-verify denied" deny "$(bp "cd $T/newdir && git push --no-verify" "$elsewhere")"
check "cd \$X && plain commit allowed" allow "$(bp 'cd "$X" && git commit -m x' "$elsewhere")"
check "non-literal cd then absolute cd into repo still judged" deny "$(bp "cd \"\$X\" && cd $T/r && git push origin main" "$elsewhere")"
check "git push --mirror with unknown dir denied" deny "$(bp 'cd "$X" && git push --mirror' "$elsewhere")"

# --- non-literal and wildcard refspecs ---
check "push origin \$BR on main denied" deny "$(bp 'BR=main; git push origin $BR')"
check "push origin command substitution on main denied" deny "$(bp 'git push origin "$(git branch --show-current)"')"
check "push origin backtick on main denied" deny "$(bp 'git push origin `git branch --show-current`')"
check "push wildcard refspec denied" deny "$(bp 'git push --prune origin "refs/heads/*:refs/heads/*"')"
check "push refs/heads/* wildcard denied" deny "$(bp 'git push origin "refs/heads/*"')"
check "push tags wildcard allowed" allow "$(bp 'git push origin "refs/tags/*"')"
check "push feature/* wildcard destination allowed" allow "$(bp 'git push origin "refs/heads/feat/*:refs/heads/feat/*"')"
on_feature "$T/r"
check "push origin \$BR on feature branch allowed" allow "$(bp 'BR=feature; git push origin $BR')"
check "push command substitution on feature branch allowed" allow "$(bp 'git push origin "$(git branch --show-current)"')"
on_main "$T/r"

# --- hook-disabling variables set earlier on the line ---
check "export HUSKY=0; commit denied" deny "$(bp 'export HUSKY=0; git commit -m x')"
check "export HUSKY=0 && commit denied" deny "$(bp 'export HUSKY=0 && git commit -m x')"
check "HUSKY=0; commit denied" deny "$(bp 'HUSKY=0; git commit -m x')"
check "newline-separated HUSKY=0 then commit denied" deny "$(bp $'HUSKY=0\ngit commit -m x')"
check "export SKIP=lint && push denied" deny "$(bp 'export SKIP=lint && git push origin feature')"
check "HUSKY=0 npm test && commit allowed" allow "$(bp 'HUSKY=0 npm test && git commit -m x')"
check "HUSKY=0 in an ended subshell allowed" allow "$(bp '(export HUSKY=0; npm test); git commit -m x')"
check "HUSKY=0 later overridden to 1 allowed" allow "$(bp 'export HUSKY=0; HUSKY=1 git commit -m x')"
check "SKIP= empty allowed" allow "$(bp 'SKIP= git commit -m x')"
check "SKIP=lint denied" deny "$(bp 'SKIP=lint git commit -m x')"

# --- tags and deletes while on the default branch ---
check "push --tags on main allowed (again)" allow "$(bp 'git push --tags')"
check "push -d origin old-branch on main allowed" allow "$(bp 'git push -d origin old-branch')"
check "push --del origin old-branch on main allowed" allow "$(bp 'git push --del origin old-branch')"
check "push -d origin main denied" deny "$(bp 'git push -d origin main')"

# --- escape ---
export CLAUDE_GIT_GUARD=off
check "CLAUDE_GIT_GUARD=off allows" allow "$(bp 'git push origin main')"
unset CLAUDE_GIT_GUARD
touch "$off"
check "fresh off-file allows" allow "$(bp 'git push --force origin main')"
touch -d '13 hours ago' "$off"
check "13-hour-old off-file ignored" deny "$(bp 'git push origin main')"
reason_has "stale off-file denial says expired" "$(bp 'git push origin main')" 'expired'
touch -d '11 hours ago' "$off"
check "11-hour-old off-file allows" allow "$(bp 'git push origin main')"
touch -d '+2 hours' "$off"
check "future-dated off-file ignored" deny "$(bp 'git push origin main')"
reason_has "future-dated off-file denial says expired" "$(bp 'git push origin main')" 'expired'
rm -f "$off"
CLAUDE_GIT_GUARD_OFF_FILE="$HOME/other.off"; export CLAUDE_GIT_GUARD_OFF_FILE
touch "$CLAUDE_GIT_GUARD_OFF_FILE"
check "off-file path override honoured" allow "$(bp 'git push origin main')"
unset CLAUDE_GIT_GUARD_OFF_FILE
iso="$(mktemp -d "$HOME/iso.XXXXXX")"; cp "$hooks/git-guard.sh" "$hooks/_git-guard-check.py" "$hooks/_git-cmd-scan.py" "$hooks/_bash-write-check.py" "$iso/"
touch "$off"
out="$(printf '%s' "$(bp 'git push origin main')" | bash "$iso/git-guard.sh" 2>&1)"
if grep -q '"permissionDecision": *"deny"' <<<"$out"; then pass=$((pass + 1)); echo "ok   - missing shared file keeps guard ON even with fresh off-file"
else fail=$((fail + 1)); echo "FAIL - missing shared file: $out"; fi
rm -f "$off"; rm -rf "$iso"

# --- fail open on bad input ---
silent "empty stdin exits 0 silently" ''
silent "malformed JSON exits 0 silently" '{not json'
silent "JSON non-object exits 0 silently" '[1,2]'
silent "JSON string exits 0 silently" '"git push --force"'
silent "empty object exits 0 silently" '{}'
silent "payload with non-string command exits 0 silently" '{"tool_input":{"command":123}}'
silent "unterminated quote exits 0 silently" "$(bp "git push origin main 'oops")"

# --- denial shape ---
nasty=$'git push origin main; echo "q\\"uote" \'s\'\n# newline\ttab'
out="$(printf '%s' "$(bp "$nasty")" | $gate)"
if jq -e '(.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "ok   - denial with quotes and newlines is valid JSON in the PreToolUse deny shape"
else fail=$((fail + 1)); echo "FAIL - denial shape: $out"; fi

# --- the hook never changes a repo ---
after="$(snap)"
if [ "$before" = "$after" ]; then pass=$((pass + 1)); echo "ok   - HEAD, index and working tree of every test repo unchanged"
else fail=$((fail + 1)); echo "FAIL - repo state changed"; diff <(echo "$before") <(echo "$after"); fi
if [ -z "$(git -C "$T/r.git" for-each-ref refs/heads | grep -v main)" ]; then pass=$((pass + 1)); echo "ok   - nothing was pushed to origin"
else fail=$((fail + 1)); echo "FAIL - origin gained refs"; fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
