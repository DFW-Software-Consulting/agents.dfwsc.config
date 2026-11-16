#!/usr/bin/env bash
# Payload-driven tests for git-guard.sh (and the git-command parts of _git-cmd-scan.py).
# Builds throwaway repos, each with a local bare repository as `origin`, under a
# temp dir, and uses a temporary HOME so the real ~/.claude/git-guard.off is never read.
# Usage: local-hooks/tests/run-git-guard-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
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
  if grep -q '"permissionDecision": *"ask"' <<<"$out" && jq -e '(.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.permissionDecision=="ask" and .hookSpecificOutput.hookEventName=="PreToolUse"' <<<"$out" >/dev/null 2>&1; then got=ask
  elif grep -q '"permissionDecision": *"deny"' <<<"$out" && jq -e '(.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.hookEventName=="PreToolUse" and (.hookSpecificOutput.permissionDecisionReason|type=="string")' <<<"$out" >/dev/null 2>&1; then got=deny; else got=allow; fi
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
check "cd \$X && push origin main denied (directory unknown, destination main)" deny "$(bp 'cd "$X" && git push origin main' "$elsewhere")"
check "-C \$X push origin main denied (directory unknown, destination main)" deny "$(bp 'git -C "$X" push origin main' "$elsewhere")"
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

# --- conditional force-with-lease (needs a valid check stamp) ---
rc="$hooks/run-checks.sh"
# mklease NAME CHECKS: repo on branch lf with a bare origin (default main) and a committed .claude/git-checks
mklease() {
  mkrepo "$1" main
  git -C "$T/$1" checkout -q -b lf; mkdir -p "$T/$1/.claude"; printf '%s\n' "$2" > "$T/$1/.claude/git-checks"
  git -C "$T/$1" add -A; git -C "$T/$1" commit -qm checks
}
mklease lp true; mklease ln none; mklease lnone true; mklease lfail false; mklease lstale true
bash "$rc" --dir "$T/lp" >/dev/null 2>&1
bash "$rc" --dir "$T/ln" >/dev/null 2>&1
bash "$rc" --dir "$T/lfail" >/dev/null 2>&1
bash "$rc" --dir "$T/lstale" >/dev/null 2>&1
echo more > "$T/lstale/more.txt"; git -C "$T/lstale" add -A; git -C "$T/lstale" commit -qm more
lbefore="$(for d in lp ln lnone lfail lstale; do echo "$d $(git -C "$T/$d" rev-parse HEAD) $(git -C "$T/$d" status --porcelain | md5sum)"; done)"
L="$T/lp"
check "lease with a valid passed stamp asks" ask "$(bp 'git push --force-with-lease origin lf' "$L")"
check "lease with a none_detected stamp asks" ask "$(bp 'git push --force-with-lease origin lf' "$T/ln")"
check "lease with no stamp denied" deny "$(bp 'git push --force-with-lease origin lf' "$T/lnone")"
check "lease with a failed stamp denied" deny "$(bp 'git push --force-with-lease origin lf' "$T/lfail")"
check "lease with a stale stamp denied" deny "$(bp 'git push --force-with-lease origin lf' "$T/lstale")"
check "lease to the default branch denied" deny "$(bp 'git push --force-with-lease origin lf:main' "$L")"
check "lease to the default branch by name denied" deny "$(bp 'git push --force-with-lease origin main' "$L")"
check "lease plus --force denied" deny "$(bp 'git push --force-with-lease --force origin lf' "$L")"
check "lease plus -f denied" deny "$(bp 'git push --force-with-lease -f origin lf' "$L")"
check "lease plus +refspec denied" deny "$(bp 'git push --force-with-lease origin +lf' "$L")"
check "--force alone still denied with a valid stamp" deny "$(bp 'git push --force origin lf' "$L")"
check "-f alone still denied with a valid stamp" deny "$(bp 'git push -f origin lf' "$L")"
check "+refspec alone still denied with a valid stamp" deny "$(bp 'git push origin +lf' "$L")"
check "--force-with-lease=branch:sha with a valid stamp asks" ask "$(bp "git push --force-with-lease=lf:abc123 origin lf" "$L")"
check "abbreviated --force-with-l asks like the full flag" ask "$(bp 'git push --force-with-l origin lf' "$L")"
check "abbreviated --force-with-l=x:y asks" ask "$(bp 'git push --force-with-l=lf:abc origin lf' "$L")"
check "abbreviated --force-with-l denied without a stamp" deny "$(bp 'git push --force-with-l origin lf' "$T/lnone")"
check "--force-if-includes alone with a valid stamp asks" ask "$(bp 'git push --force-if-includes origin lf' "$L")"
check "lease plus --force-if-includes with a valid stamp asks" ask "$(bp 'git push --force-with-lease --force-if-includes origin lf' "$L")"
check "abbreviated --force-i asks with a valid stamp" ask "$(bp 'git push --force-i origin lf' "$L")"
check "abbreviated --forc (ambiguous) still denied" deny "$(bp 'git push --forc origin lf' "$L")"
check "lease with no refspec on the current branch asks" ask "$(bp 'git push --force-with-lease' "$L")"
check "lease HEAD refspec asks" ask "$(bp 'git push --force-with-lease origin HEAD' "$L")"
check "lease with undeterminable directory denied" deny "$(bp 'cd "$X" && git push --force-with-lease origin lf' "$elsewhere")"
check "lease from a non-repo directory denied" deny "$(bp 'git push --force-with-lease origin lf' "$elsewhere")"
check "lease of a ref that is not the current branch denied" deny "$(bp 'git push --force-with-lease origin other' "$L")"
check "lease with another source ref denied" deny "$(bp 'git push --force-with-lease origin other:lf' "$L")"
check "lease -C <repo> from another cwd asks" ask "$(bp "git -C $L push --force-with-lease origin lf" "$elsewhere")"
check "lease dry run allowed" allow "$(bp 'git push --force-with-lease -n origin lf' "$L")"
check "lease asks for a subagent too" ask "$(bp 'git push --force-with-lease origin lf' "$L" | jq '.agent_id="a1"')"
out="$(printf '%s' "$(bp 'git push --force-with-lease origin lf' "$L")" | $gate)"
short="$(git -C "$L" rev-parse HEAD | cut -c1-10)"
if jq -e --arg s "$short" '.hookSpecificOutput.permissionDecision=="ask" and (.hookSpecificOutput.permissionDecisionReason | test("origin") and test("lf") and test($s) and test("passed"))' <<<"$out" >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "ok   - ask reason names remote, branch, short sha and stamp status"
else fail=$((fail + 1)); echo "FAIL - ask reason: $out"; fi
out="$(printf '%s' "$(bp 'git push --force-with-lease origin lf' "$T/ln")" | $gate)"
if jq -e '.hookSpecificOutput.permissionDecisionReason | test("none_detected")' <<<"$out" >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "ok   - ask reason for a none_detected stamp says none_detected"
else fail=$((fail + 1)); echo "FAIL - none_detected reason: $out"; fi
# --- an ask is soft: the rest of the line is still judged ---
check "lease then push -f denied" deny "$(bp 'git push --force-with-lease origin lf && git push -f origin other' "$L")"
check "lease then commit --no-verify denied" deny "$(bp 'git push --force-with-lease origin lf && git commit --no-verify -m x' "$L")"
check "lease then push origin main denied" deny "$(bp 'git push --force-with-lease origin lf && git push origin main' "$L")"
check "commit --no-verify then lease denied" deny "$(bp 'git commit --no-verify -m x && git push --force-with-lease origin lf' "$L")"
check "lease then git status asks" ask "$(bp 'git push --force-with-lease origin lf && git status' "$L")"
check "two lease pushes on one line give one ask" ask "$(bp "git push --force-with-lease origin lf; git -C $T/ln push --force-with-lease origin lf" "$L")"
out="$(printf '%s' "$(bp "git push --force-with-lease origin lf; git -C $T/ln push --force-with-lease origin lf" "$L")" | $gate)"
if jq -e '.hookSpecificOutput.permissionDecisionReason | ([match("force-with-lease push of";"g")] | length) == 2 and test("passed") and test("none_detected")' <<<"$out" >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "ok   - the single ask reason covers both lease pushes"
else fail=$((fail + 1)); echo "FAIL - two-lease reason: $out"; fi
if jq -e '.hookSpecificOutput.permissionDecisionReason | test("\\.\\.") | not' <<<"$(printf '%s' "$(bp 'git push --force-with-lease origin lf' "$L")" | $gate)" >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "ok   - ask reason has no doubled period"
else fail=$((fail + 1)); echo "FAIL - doubled period in ask reason"; fi
reason_has "lease denial without a stamp says to run git-verify" "$(bp 'git push --force-with-lease origin lf' "$T/lnone")" 'git-verify.*retry'
reason_has "lease denial without a directory says own worktree" "$(bp 'cd "$X" && git push --force-with-lease origin lf' "$elsewhere")" "own worktree"
touch "$off"
check "fresh off-file allows a lease push without a stamp" allow "$(bp 'git push --force-with-lease origin lf' "$T/lnone")"
rm -f "$off"
export CLAUDE_GIT_GUARD=off
check "env off allows a lease push without a stamp" allow "$(bp 'git push --force-with-lease origin lf' "$T/lnone")"
unset CLAUDE_GIT_GUARD
lafter="$(for d in lp ln lnone lfail lstale; do echo "$d $(git -C "$T/$d" rev-parse HEAD) $(git -C "$T/$d" status --porcelain | md5sum)"; done)"
if [ "$lbefore" = "$lafter" ]; then pass=$((pass + 1)); echo "ok   - lease repos unchanged by the hook"
else fail=$((fail + 1)); echo "FAIL - lease repos changed"; fi

# --- unknown directory, wrapper bodies and explicit git directories ---
on_main "$T/r"
R="$T/r"; X="$elsewhere"
# rules that need no directory: explicit git directories
check "GIT_DIR=x push --force denied" deny "$(bp 'GIT_DIR=x git push --force' "$X")"
check "GIT_DIR=\$V push --force denied" deny "$(bp 'GIT_DIR="$V" git push --force origin x' "$X")"
check "GIT_WORK_TREE=x push -f denied" deny "$(bp 'GIT_WORK_TREE=x git push -f origin x' "$X")"
check "--git-dir=x push --force denied" deny "$(bp 'git --git-dir=x push --force origin x' "$X")"
check "--git-dir x push -f denied" deny "$(bp 'git --git-dir x push -f origin x' "$X")"
check "--work-tree=x push --force denied" deny "$(bp 'git --work-tree=x push --force origin x' "$X")"
check "GIT_DIR=x commit --no-verify denied" deny "$(bp 'GIT_DIR=x git commit --no-verify -m m' "$X")"
check "--git-dir=x commit -n denied" deny "$(bp 'git --git-dir=x commit -n -m m' "$X")"
check "GIT_DIR=x push --mirror denied" deny "$(bp 'GIT_DIR=x git push --mirror' "$X")"
check "--git-dir=x push --all denied" deny "$(bp 'git --git-dir=x push --all' "$X")"
check "GIT_DIR=x plain commit allowed" allow "$(bp 'GIT_DIR=x git commit -m m' "$X")"
check "GIT_DIR=x push origin feat/x allowed" allow "$(bp 'GIT_DIR=x git push origin feat/x' "$X")"
check "GIT_DIR=x push origin main denied (directory not judged)" deny "$(bp 'GIT_DIR=x git push origin main' "$X")"
check "env -C x commit --no-verify denied" deny "$(bp 'env -C x git commit --no-verify -m m' "$X")"
check "env -C \$V push --force denied" deny "$(bp 'env -C "$V" git push --force origin x' "$X")"
check "env -C x plain commit allowed" allow "$(bp 'env -C x git commit -m m' "$X")"
check "env -C repo push origin main denied (known directory)" deny "$(bp "env -C $R git push origin main" "$X")"
check "env -C repo push origin feature allowed" allow "$(bp "env -C $R git push origin feature" "$X")"
check "HUSKY=0 env -C x commit denied" deny "$(bp 'HUSKY=0 env -C x git commit -m m' "$X")"
# followed command bodies
check "bash -c push --force denied" deny "$(bp "bash -c 'git push --force'" "$X")"
check "sh -c push -f denied" deny "$(bp "sh -c 'git push -f origin x'" "$X")"
check "bash -lc push --force denied" deny "$(bp "bash -lc 'git push --force origin x'" "$X")"
check "eval push --force denied" deny "$(bp "eval 'git push --force'" "$X")"
check "eval with several words denied" deny "$(bp 'eval git push --force origin x' "$X")"
check "bash -c commit --no-verify denied" deny "$(bp "bash -c 'git commit --no-verify -m m'" "$X")"
check "bash -c push --mirror denied" deny "$(bp "bash -c 'git push --mirror'" "$X")"
check "bash -c push --all denied" deny "$(bp "bash -c 'cd \"\$V\" && git push --all'" "$X")"
check "bash -c with literal cd to main repo push origin main denied" deny "$(bp "bash -c 'cd $R && git push origin main'" "$X")"
check "HUSKY=0 bash -c commit denied" deny "$(bp "HUSKY=0 bash -c 'git commit -m m'" "$X")"
check "export HUSKY=0; bash -c commit denied" deny "$(bp "export HUSKY=0; bash -c 'git commit -m m'" "$X")"
nest() { local c="$1" k; for k in $(seq "$2"); do c="$(printf '%s -c %q' "${3:-bash}" "$c")"; done; printf '%s' "$c"; }
check "bash -c nested twice push --force denied" deny "$(bp "$(nest 'git push --force' 2)" "$X")"
check "three levels deep push --force denied" deny "$(bp "$(nest 'git push --force' 3 sh)" "$X")"
check "three levels deep commit --no-verify denied" deny "$(bp "$(nest 'git commit --no-verify -m m' 3)" "$X")"
check "three levels deep plain push of a feature branch allowed" allow "$(bp "$(nest 'git push -u origin feat/x' 3)" "$X")"
check "four levels deep is not followed (documented limit)" allow "$(bp "$(nest 'git push --force' 4)" "$X")"
check "wrapper later on the line judged" deny "$(bp "git status && bash -c 'git push -f'" "$X")"
check "bash -c plain commit allowed" allow "$(bp "bash -c 'git commit -m m'" "$X")"
check "bash -c push origin feat/x allowed" allow "$(bp "bash -c 'git push origin feat/x'" "$X")"
check "bash -c push origin main from a non-repo directory allowed (directory known)" allow "$(bp "bash -c 'git push origin main'" "$X")"
check "bash -c push origin main from the repo denied" deny "$(bp "bash -c 'git push origin main'" "$R")"
check "bash -c with a script file allowed" allow "$(bp 'bash ./deploy.sh' "$X")"
silent "bash -c with an unparseable body is silent" "$(bp "bash -c 'git push --force \\'oops'" "$X")"
# text as data
check "echo with a force push inside quotes allowed" allow "$(bp 'echo "git push --force"' "$X")"
check "commit message mentioning a force push allowed" allow "$(bp 'git commit -m "never run git push --force or git commit --no-verify"' "$R")"
check "cd \$V && commit message mentioning a force push allowed" allow "$(bp 'cd "$V" && git commit -m "do not git push -f"' "$X")"
check "here-document body mentioning a force push allowed" allow "$(bp $'cd "$V" && cat <<EOF\ngit push --force\nbash -c "git commit --no-verify"\nEOF' "$X")"
check "bash -c echo of a force push allowed" allow "$(bp "bash -c 'echo \"git push --force\"'" "$X")"
check "grep for a force push allowed" allow "$(bp "git -C \"\$V\" log --grep='git push --force'" "$X")"
# default-branch rule with an unknown directory
check "unknown dir: bare push denied" deny "$(bp 'git -C "$V" push' "$X")"
check "unknown dir: push origin (no destination) denied" deny "$(bp 'cd "$V" && git push origin' "$X")"
check "unknown dir: push origin HEAD denied" deny "$(bp 'git -C "$V" push origin HEAD' "$X")"
check "unknown dir: push origin HEAD:main denied" deny "$(bp 'git -C "$V" push origin HEAD:main' "$X")"
check "unknown dir: push origin master denied" deny "$(bp 'git -C "$V" push origin master' "$X")"
check "unknown dir: push origin refs/heads/main denied" deny "$(bp 'git -C "$V" push origin refs/heads/main' "$X")"
check "unknown dir: push origin feat:main denied" deny "$(bp 'git -C "$V" push origin feat:main' "$X")"
check "unknown dir: push origin :main denied" deny "$(bp 'git -C "$V" push origin :main' "$X")"
check "unknown dir: push origin refs/heads/* denied" deny "$(bp 'git -C "$V" push origin "refs/heads/*"' "$X")"
check "unknown dir: push origin \$BR denied" deny "$(bp 'git -C "$V" push origin $BR' "$X")"
check "unknown dir: cd - && push denied" deny "$(bp 'cd - && git push' "$X")"
check "unknown dir: popd && push denied" deny "$(bp 'popd && git push' "$X")"
check "unknown dir: pushd \$V && push denied" deny "$(bp 'pushd "$V" && git push' "$X")"
check "unknown dir: subshell push denied" deny "$(bp '(cd "$V" && git push)' "$X")"
check "unknown dir: -u origin feat/x allowed" allow "$(bp 'git -C "$V" push -u origin feat/x' "$X")"
check "unknown dir: cd and push -u origin feat/x allowed" allow "$(bp 'cd "$V" && git push -u origin feat/x' "$X")"
check "unknown dir: push origin HEAD:feat/x allowed" allow "$(bp 'git -C "$V" push origin HEAD:feat/x' "$X")"
check "unknown dir: push origin feature allowed" allow "$(bp 'git -C "$V" push origin feature' "$X")"
check "unknown dir: push --tags allowed" allow "$(bp 'git -C "$V" push --tags' "$X")"
check "unknown dir: push --tags origin allowed" allow "$(bp 'git -C "$V" push --tags origin' "$X")"
check "unknown dir: push --delete origin old allowed" allow "$(bp 'git -C "$V" push --delete origin old-branch' "$X")"
check "unknown dir: dry run to main allowed" allow "$(bp 'git -C "$V" push -n origin main' "$X")"
check "unknown dir: status allowed" allow "$(bp 'git -C "$V" status' "$X")"
check "unknown dir: lease push still denied" deny "$(bp 'git -C "$V" push --force-with-lease origin feat' "$X")"
check "unknown dir: wrapper body bare push denied" deny "$(bp "bash -c 'cd \"\$V\" && git push'" "$X")"
check "unknown dir: wrapper body push -u origin feat/x allowed" allow "$(bp "bash -c 'cd \"\$V\" && git push -u origin feat/x'" "$X")"
check "unknown dir: several commands, any denial wins" deny "$(bp 'git -C "$V" push -u origin feat/x && git -C "$W" push origin main' "$X")"
check "unknown dir: several commands, none denied" allow "$(bp 'git -C "$V" push -u origin feat/x && git -C "$W" push origin feat/y' "$X")"
check "unknown dir: mktemp directory gets no exception (push main)" deny "$(bp 'T=$(mktemp -d) && cd "$T" && git push origin main' "$X")"
check "unknown dir: mktemp directory gets no exception (bare push)" deny "$(bp 'cd "$(mktemp -d)" && git push' "$X")"
check "unknown dir: mktemp directory push -u origin feat/x allowed" allow "$(bp 'T=$(mktemp -d) && cd "$T" && git push -u origin feat/x' "$X")"
check "unknown dir: mktemp directory force push denied" deny "$(bp 'T=$(mktemp -d) && cd "$T" && git push --force origin x' "$X")"
check "unknown dir: payload without cwd keeps old silence" allow "$(jq -n '{tool_name:"Bash",tool_input:{command:"git push origin main"}}')"
# plain resolvable assignments are judged like a literal path
check "assigned path of the repo: push origin main denied" deny "$(bp "W=$R; git -C \"\$W\" push origin main" "$X")"
check "assigned path of the repo: cd and bare push on main denied" deny "$(bp "W=$R && cd \"\$W\" && git push" "$X")"
check "assigned path of the repo: push origin feature allowed" allow "$(bp "W=$R; git -C \"\$W\" push origin feature" "$X")"
check "assigned path of the repo: -u origin feat/x allowed" allow "$(bp "W=$R; cd \"\$W\" && git push -u origin feat/x" "$X")"
check "assigned path outside any repo: push origin main allowed" allow "$(bp "W=$X; git -C \"\$W\" push origin main" "$X")"
check "assigned path via export: push origin main denied" deny "$(bp "export W=$R; cd \"\$W\" && git push origin main" "$X")"
check "doubtful assignment is unknown: push origin main denied" deny "$(bp "true && W=$R; git -C \"\$W\" push origin main" "$X")"
check "backtick reassignment drops the stale outside-repo value: push origin main denied" deny "$(bp "W=$X; W=\`pwd\`; git -C \"\$W\" push origin main" "$X")"
check "assigned path then wrapper body judged in that repo" deny "$(bp "W=$R; eval 'cd \"\$W\" && git push origin main'" "$X")"

# --- review round: escapes, prefixes, fed text, refspec spellings, directories not there yet, big lines ---
dq() { local t="${1//\\/\\\\}"; t="${t//\"/\\\"}"; t="${t//\$/\\\$}"; printf 'bash -c "%s"' "$t"; }
d1="$(dq 'git push --force origin x')"; d2="$(dq "$d1")"; d3="$(dq "$d2")"
check "double-quoted body with escaped quotes: push --force denied" deny "$(bp "$(dq 'cd "$V" && git push --force')" "$X")"
check "two levels of escaped quotes denied" deny "$(bp "$d2" "$X")"
check "three levels of escaped quotes denied" deny "$(bp "$d3" "$X")"
check "three levels of escaped quotes: commit --no-verify denied" deny "$(bp "$(dq "$(dq "$(dq 'git commit --no-verify -m "m"')")")" "$X")"
check "escaped quotes, plain feature push allowed" allow "$(bp "$(dq 'cd "$V" && git push -u origin feat/x')" "$X")"
check "unparseable body holding a force push denied" deny "$(bp "bash -c \"git push --force 'oops\"" "$X")"
check "unparseable nested body holding a push denied" deny "$(bp "$(dq "bash -c \"git push origin feat 'oops\"")" "$X")"
check "unparseable body holding a hook bypass denied" deny "$(bp "sh -c \"git commit --no-verify -m 'oops\"" "$X")"
silent "unparseable body with no git command is silent" "$(bp "bash -c \"echo 'oops\"" "$X")"
check "commit message mentioning a force push inside a body is data" allow "$(bp "bash -c 'git commit -m \"do not git push --force\"'" "$X")"
check "env -C x bash -c push --force denied" deny "$(bp "env -C x bash -c 'git push --force'" "$X")"
check "builtin cd and push --force denied" deny "$(bp 'builtin cd "$V" && git push -f' "$X")"
check "builtin cd \$V && push origin main denied" deny "$(bp 'builtin cd "$V" && git push origin main' "$X")"
check "command cd \$V && bare push denied" deny "$(bp 'command cd "$V" && git push' "$X")"
# prefix commands that hide the command position
for f in 'timeout 5 git push --force' 'timeout -k 2 10 git push --force' 'timeout 5s git commit --no-verify -m m' 'stdbuf -oL git push -f' \
  'setsid git push --force' 'setsid -w git push --force' 'ionice -c 3 git push --force' 'ionice git commit -n -m m' 'nice git push --force' \
  'nice -n 5 git push --force' 'doas git push --force' 'doas -u root git push -f' 'sudo -u root git push --force' \
  "env -S 'git push --force'" "env -S 'git commit --no-verify -m m'" 'env -i git push --force' 'env -u FOO git push --force' \
  'time git push --force' 'exec git push --force' 'nohup git push --force' 'xargs -n 1 git push --force' 'sudo timeout 5 nice git push -f'; do
  check "prefix: $f denied" deny "$(bp "$f" "$X")"
done
check "timeout 5 git push -u origin feat/x allowed" allow "$(bp 'timeout 5 git push -u origin feat/x' "$X")"
check "stdbuf -oL git status allowed" allow "$(bp 'stdbuf -oL git status' "$X")"
check "env -S with a plain commit allowed" allow "$(bp "env -S 'git commit -m m'" "$X")"
# text fed to a shell
for f in "echo 'git push --force' | bash" "echo 'git push --force origin x' | sh" 'echo git push --force | bash' "printf '%s\n' 'git commit --no-verify -m m' | sh" \
  "bash <<< 'git push --force'" "bash -s <<< 'git push -f origin x'" $'bash <<EOF\ngit push --force\nEOF' $'cat <<EOF | bash\ngit push --force\nEOF' \
  $'sh <<\'EOF\'\ngit commit --no-verify -m m\nEOF' "echo 'git push --mirror' | bash" "echo 'cd \$V && git push --force' | sudo bash"; do
  check "fed to a shell: ${f//$'\n'/ ; } denied" deny "$(bp "$f" "$X")"
done
check "pipe to a shell, harmless text allowed" allow "$(bp "echo 'git status' | bash" "$X")"
check "pipe to a shell, feature push allowed" allow "$(bp "echo 'git push -u origin feat/x' | bash" "$X")"
check "text piped to cat is data" allow "$(bp "echo 'git push --force' | cat" "$X")"
check "text piped to grep is data" allow "$(bp "echo 'git push --force' | grep push" "$X")"
check "here-document into cat is data" allow "$(bp $'cat <<EOF\ngit push --force\nEOF' "$X")"
check "here-string into cat is data" allow "$(bp "cat <<< 'git push --force'" "$X")"
check "bash script file after a pipe is not fed text" allow "$(bp "echo 'git push --force' | bash ./run.sh" "$X")"
check "bash -c body after a pipe judged as a body" deny "$(bp "echo hi | bash -c 'git push --force'" "$X")"
# refspec spellings with an unknown directory
check "unknown dir: push origin @ denied" deny "$(bp 'git -C "$V" push origin @' "$X")"
check "unknown dir: push origin : denied" deny "$(bp 'git -C "$V" push origin :' "$X")"
check "unknown dir: push origin feat:heads/main denied" deny "$(bp 'git -C "$V" push origin feat:heads/main' "$X")"
check "unknown dir: push origin HEAD:heads/master denied" deny "$(bp 'git -C "$V" push origin HEAD:heads/master' "$X")"
check "unknown dir: --repo=origin feat allowed" allow "$(bp 'git -C "$V" push --repo=origin feat' "$X")"
check "unknown dir: --repo origin feat allowed" allow "$(bp 'git -C "$V" push --repo origin feat' "$X")"
check "unknown dir: --repo=origin main denied" deny "$(bp 'git -C "$V" push --repo=origin main' "$X")"
check "unknown dir: push origin tag v1 allowed" allow "$(bp 'git -C "$V" push origin tag v1' "$X")"
check "unknown dir: push origin heads/feat allowed" allow "$(bp 'git -C "$V" push origin heads/feat' "$X")"
# a directory that does not exist yet is judged by its nearest existing ancestor
check "mkdir t && cd t && push origin main in the repo denied" deny "$(bp 'mkdir t && cd t && git push origin main' "$R")"
check "cd newdir/deeper && bare push in the repo denied" deny "$(bp "cd $R/newdir/deeper && git push" "$X")"
check "mkdir t && cd t && push origin feature allowed" allow "$(bp 'mkdir t && cd t && git push origin feature' "$R")"
# mktemp gets no exception, whatever its form
check "mktemp -p repo then push main denied" deny "$(bp "T=\$(mktemp -d -p $R); cd \"\$T\" && git push origin main" "$X")"
# a line over the analysis budget keeps the rules that need no directory
big="$(for k in $(seq 400); do printf 'git status; '; done)"
check "400 git commands then a force push denied" deny "$(bp "${big}git push --force origin x" "$X")"
check "400 git commands then a hook bypass denied" deny "$(bp "${big}git commit --no-verify -m m" "$X")"
check "400 git commands then --mirror denied" deny "$(bp "${big}git push --mirror" "$X")"
check "400 git commands then a plain push allowed" allow "$(bp "${big}git push -u origin feat/x" "$X")"
check "400 git commands, no push at all allowed" allow "$(bp "${big}git log" "$X")"

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
iso="$(mktemp -d "$HOME/iso.XXXXXX")"; cp "$hooks/git-guard.sh" "$hooks/_git-guard-check.py" "$hooks/_git-cmd-scan.py" "$hooks/_bash-write-check.py" "$hooks/_cmd_dirs.py" "$iso/"
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
