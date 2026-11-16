#!/usr/bin/env bash
# Tests for git-facts.sh and _git_facts.py.
# Builds throwaway repos under a temp dir with a temporary HOME. Needs no
# network: remotes are local bare repositories.
# Usage: local-hooks/tests/run-git-facts-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
script="$hooks/git-facts.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

T="$(mktemp -d "$HOME/t.XXXXXX")"
facts() { bash "$script" --dir "$1" 2>/dev/null; }
f() { jq -c "$2" <<<"$(facts "$1")"; }   # f DIR JQ-FILTER

# mkrepo NAME  (one commit on main, no remote)
mkrepo() {
  local d="$T/$1"; git init -q "$d"; echo a > "$d/a.txt"
  git -C "$d" add -A; git -C "$d" commit -qm init; echo "$d"
}
# mkremote NAME  (repo with a local bare origin, main pushed and tracked)
mkremote() {
  local d; d="$(mkrepo "$1")"
  git init -q --bare "$T/$1.git"
  git -C "$d" remote add origin "$T/$1.git"
  git -C "$d" push -q -u origin main 2>/dev/null
  echo "$d"
}
commit() { echo "$2" >> "$1/$3"; git -C "$1" add -A; git -C "$1" commit -qm "$2"; }

# --- basics, no remote ---
r="$(mkrepo plain)"
eq "exit 0 on a repo" "$(bash "$script" --dir "$r" >/dev/null 2>&1; echo $?)" 0
eq "output is one json object" "$(facts "$r" | jq -r type)" object
eq "repo_root" "$(f "$r" .repo_root)" "\"$(cd "$r" && pwd -P)\""
eq "branch" "$(f "$r" .branch)" '"main"'
eq "head is the commit" "$(f "$r" .head)" "\"$(git -C "$r" rev-parse HEAD)\""
eq "not detached" "$(f "$r" .detached)" false
eq "default branch with no remote" "$(f "$r" .default_branch)" '"main"'
eq "no remote" "$(f "$r" .has_remote)" false
eq "no upstream" "$(f "$r" .upstream)" null
eq "ahead null without upstream" "$(f "$r" .ahead)" null
eq "behind null without upstream" "$(f "$r" .behind)" null
eq "clean tree" "$(f "$r" .clean)" true
eq "not a linked worktree" "$(f "$r" .linked_worktree)" false
eq "no pr template" "$(f "$r" .pr_template)" null
eq "no issue templates" "$(f "$r" .issue_templates)" '[]'
eq "no commitlint" "$(f "$r" .commitlint)" false
eq "no husky" "$(f "$r" .hooks.husky)" false
eq "no lint-staged" "$(f "$r" .hooks.lint_staged)" false
eq "no hooksPath" "$(f "$r" .hooks.hooks_path)" null
eq "no codeowners" "$(f "$r" .codeowners)" null
eq "no changes on the default branch" "$(f "$r" .changes.total)" 0
eq "dir defaults to cwd" "$(cd "$r" && bash "$script" | jq -r .branch)" main
eq "subdirectory resolves to root" "$(mkdir -p "$r/sub"; f "$r/sub" .repo_root)" "\"$(cd "$r" && pwd -P)\""

# --- dirty tree ---
echo x > "$r/new.txt"
eq "untracked file is not clean" "$(f "$r" .clean)" false
rm "$r/new.txt"; echo b >> "$r/a.txt"
eq "modified file is not clean" "$(f "$r" .clean)" false
git -C "$r" checkout -q -- a.txt
eq "clean again" "$(f "$r" .clean)" true

# --- remote, upstream, ahead/behind ---
r="$(mkremote rem)"
eq "has remote" "$(f "$r" .has_remote)" true
eq "upstream" "$(f "$r" .upstream)" '"origin/main"'
eq "in sync ahead" "$(f "$r" .ahead)" 0
eq "in sync behind" "$(f "$r" .behind)" 0
git -C "$r" checkout -q -b feat
eq "new branch has no upstream" "$(f "$r" .upstream)" null
commit "$r" one a.txt; commit "$r" two a.txt
git -C "$r" push -q -u origin feat 2>/dev/null
commit "$r" three a.txt
eq "feature upstream" "$(f "$r" .upstream)" '"origin/feat"'
eq "ahead by one" "$(f "$r" .ahead)" 1
eq "behind zero" "$(f "$r" .behind)" 0
other="$T/rem-other"; git clone -q "$T/rem.git" "$other" 2>/dev/null
git -C "$other" checkout -q feat; commit "$other" remote-side b.txt; git -C "$other" push -q origin feat 2>/dev/null
git -C "$r" fetch -q origin
eq "diverged ahead" "$(f "$r" .ahead)" 1
eq "diverged behind" "$(f "$r" .behind)" 1

# --- pushed or not (same-name remote branch) ---
r="$(mkremote pub)"
git -C "$r" worktree add -q -b nb "$T/pub-nb" origin/main 2>/dev/null
eq "branch from origin/main tracks the default branch" "$(f "$T/pub-nb" .upstream)" '"origin/main"'
eq "branch from origin/main is not pushed" "$(f "$T/pub-nb" .pushed)" false
eq "not pushed: push_ref null" "$(f "$T/pub-nb" .push_ref)" null
eq "not pushed: push_ahead null" "$(f "$T/pub-nb" .push_ahead)" null
eq "push remote defaults to origin" "$(f "$T/pub-nb" .push_remote)" '"origin"'
commit "$T/pub-nb" work a.txt
git -C "$T/pub-nb" push -q origin nb 2>/dev/null
eq "pushed without -u: pushed" "$(f "$T/pub-nb" .pushed)" true
eq "pushed without -u: push_ref" "$(f "$T/pub-nb" .push_ref)" '"origin/nb"'
eq "pushed without -u: in sync ahead" "$(f "$T/pub-nb" .push_ahead)" 0
eq "pushed without -u: in sync behind" "$(f "$T/pub-nb" .push_behind)" 0
eq "upstream fields keep their meaning" "$(f "$T/pub-nb" .ahead)" 1
commit "$T/pub-nb" more a.txt
eq "pushed and ahead" "$(f "$T/pub-nb" .push_ahead)" 1
git -C "$r" worktree add -q -b dn "$T/pub-dn" origin/main 2>/dev/null
git -C "$r" push -q origin dn:other 2>/dev/null; git -C "$r" fetch -q origin
git -C "$T/pub-dn" branch -q -u origin/other
eq "differently named upstream" "$(f "$T/pub-dn" .upstream)" '"origin/other"'
eq "differently named upstream alone is not pushed" "$(f "$T/pub-dn" .pushed)" false
eq "differently named upstream: push_ref null" "$(f "$T/pub-dn" .push_ref)" null
git -C "$T/pub-nb" config branch.nb.pushRemote fork
eq "pushRemote setting wins" "$(f "$T/pub-nb" .push_remote)" '"fork"'
eq "no remote branch under that remote: not pushed" "$(f "$T/pub-nb" .pushed)" false
eq "no remote: not pushed" "$(f "$(mkrepo nopush)" .pushed)" false
git -C "$r" checkout -q --detach
eq "detached: not pushed" "$(f "$r" .pushed)" false

# --- cut from a non-default remote branch ---
git -C "$r" push -q origin main:develop 2>/dev/null; git -C "$r" fetch -q origin
git -C "$r" worktree add -q -b feat-dev "$T/pub-dev" origin/develop 2>/dev/null
commit "$T/pub-dev" dev-work a.txt
eq "cut from develop: upstream is develop" "$(f "$T/pub-dev" .upstream)" '"origin/develop"'
eq "cut from develop, never pushed: not pushed" "$(f "$T/pub-dev" .pushed)" false
git -C "$T/pub-dev" push -q origin feat-dev 2>/dev/null
eq "cut from develop, plain push: pushed" "$(f "$T/pub-dev" .pushed)" true
eq "cut from develop, plain push: in sync" "$(f "$T/pub-dev" .push_ahead)" 0

# --- push remote selection ---
r="$(mkrepo oneremote)"; git init -q --bare "$T/oneremote.git"
git -C "$r" remote add upstream "$T/oneremote.git"
eq "single non-origin remote is used" "$(f "$r" .push_remote)" '"upstream"'
git init -q --bare "$T/second.git"; git -C "$r" remote add other "$T/second.git"
eq "several remotes, no origin: no push remote" "$(f "$r" .push_remote)" null
eq "several remotes, no origin: not pushed" "$(f "$r" .pushed)" false
git -C "$r" remote add origin "$T/second.git"
eq "origin preferred when present" "$(f "$r" .push_remote)" '"origin"'
eq "no remotes: no push remote" "$(f "$(mkrepo noremote)" .push_remote)" null

# --- default branch ---
eq "default branch from origin/HEAD" "$(git -C "$r" remote set-head origin main >/dev/null 2>&1; f "$r" .default_branch)" '"main"'
r2="$(mkrepo trunk)"; git -C "$r2" branch -m master
eq "default branch falls back to master" "$(f "$r2" .default_branch)" '"master"'
git init -q --bare "$T/dev.git"; r3="$(mkrepo dev)"; git -C "$r3" branch -m develop
git -C "$r3" remote add origin "$T/dev.git"; git -C "$r3" push -q origin develop 2>/dev/null
git --git-dir="$T/dev.git" symbolic-ref HEAD refs/heads/develop
git -C "$r3" fetch -q origin; git -C "$r3" remote set-head origin -a >/dev/null 2>&1
eq "default branch develop via origin/HEAD" "$(f "$r3" .default_branch)" '"develop"'

# --- changed lines against the default branch, lockfiles excluded ---
r="$(mkremote chg)"; git -C "$r" checkout -q -b feat
printf '1\n2\n3\n' > "$r/code.js"; printf 'l\nl\nl\nl\nl\n' > "$r/package-lock.json"
printf 'x\n' > "$r/yarn.lock"
git -C "$r" add -A; git -C "$r" commit -qm change
eq "files counted without lockfiles" "$(f "$r" .changes.files)" 1
eq "insertions without lockfiles" "$(f "$r" .changes.insertions)" 3
eq "deletions" "$(f "$r" .changes.deletions)" 0
eq "total" "$(f "$r" .changes.total)" 3
eq "base is origin/main" "$(f "$r" .changes.base)" '"origin/main"'
eq "excluded lockfiles listed" "$(f "$r" '.changes.excluded | sort')" '["package-lock.json","yarn.lock"]'
printf '1\n' > "$r/code.js"; git -C "$r" commit -qam shrink
eq "no deletions after shrink" "$(f "$r" .changes.deletions)" 0
eq "net diff after shrink" "$(f "$r" .changes.insertions)" 1
git -C "$r" mv code.js moved.js; git -C "$r" commit -qm rename
eq "rename is one file" "$(f "$r" .changes.files)" 1
printf '\0\1\2\0' > "$r/bin.dat"; git -C "$r" add -A; git -C "$r" commit -qm bin
eq "binary file counts as a file, zero lines" "$(f "$r" '[.changes.files, .changes.total] | @csv')" '"2,1"'
r="$(mkrepo nobase)"; git -C "$r" branch -m other
eq "no default branch ref still prints zero changes" "$(f "$r" .changes.total)" 0

# --- templates, commitlint, hooks, codeowners ---
r="$(mkrepo tpl)"; mkdir -p "$r/.github/ISSUE_TEMPLATE" "$r/.husky"
echo "# pr" > "$r/.github/pull_request_template.md"
echo "# bug" > "$r/.github/ISSUE_TEMPLATE/bug.md"
echo "name: f" > "$r/.github/ISSUE_TEMPLATE/feature.yml"
echo "blank_issues_enabled: false" > "$r/.github/ISSUE_TEMPLATE/config.yml"
echo "* @owner" > "$r/.github/CODEOWNERS"
echo "module.exports={}" > "$r/commitlint.config.js"
eq "pr template, lowercase name" "$(f "$r" .pr_template)" '".github/pull_request_template.md"'
eq "issue templates include md and yml, not config" "$(f "$r" .issue_templates)" '[".github/ISSUE_TEMPLATE/bug.md",".github/ISSUE_TEMPLATE/feature.yml"]'
eq "codeowners path" "$(f "$r" .codeowners)" '".github/CODEOWNERS"'
eq "commitlint config file" "$(f "$r" .commitlint)" true
eq "husky directory" "$(f "$r" .hooks.husky)" true
rm "$r/.github/pull_request_template.md"; echo "# pr" > "$r/.github/PULL_REQUEST_TEMPLATE.md"
eq "pr template, upper-case name" "$(f "$r" .pr_template)" '".github/PULL_REQUEST_TEMPLATE.md"'
rm "$r/.github/PULL_REQUEST_TEMPLATE.md"; mkdir -p "$r/docs"; echo "# pr" > "$r/docs/pull_request_template.md"
eq "pr template in docs" "$(f "$r" .pr_template)" '"docs/pull_request_template.md"'
rm "$r/docs/pull_request_template.md"; mkdir -p "$r/.github/PULL_REQUEST_TEMPLATE"; echo "# pr" > "$r/.github/PULL_REQUEST_TEMPLATE/default.md"
eq "pr template directory default" "$(f "$r" .pr_template)" '".github/PULL_REQUEST_TEMPLATE/default.md"'
r="$(mkrepo pkg)"
echo '{"devDependencies":{"@commitlint/cli":"1","lint-staged":"1","husky":"9"}}' > "$r/package.json"
eq "commitlint from package.json dependency" "$(f "$r" .commitlint)" true
eq "lint-staged from package.json" "$(f "$r" .hooks.lint_staged)" true
eq "husky from package.json" "$(f "$r" .hooks.husky)" true
r="$(mkrepo pkg2)"; echo '{"lint-staged":{"*.js":"x"},"commitlint":{}}' > "$r/package.json"
eq "lint-staged key" "$(f "$r" .hooks.lint_staged)" true
eq "commitlint key" "$(f "$r" .commitlint)" true
r="$(mkrepo hp)"; git -C "$r" config core.hooksPath .githooks
eq "core.hooksPath" "$(f "$r" .hooks.hooks_path)" '".githooks"'
r="$(mkrepo rootco)"; echo "* @o" > "$r/CODEOWNERS"
eq "root CODEOWNERS" "$(f "$r" .codeowners)" '"CODEOWNERS"'
r="$(mkrepo badpkg)"; echo 'not json' > "$r/package.json"
eq "invalid package.json is tolerated" "$(f "$r" .commitlint)" false

# --- linked worktree ---
r="$(mkrepo main-wt)"; git -C "$r" worktree add -q -b wtb "$T/linked" 2>/dev/null
eq "linked worktree" "$(f "$T/linked" .linked_worktree)" true
eq "linked worktree branch" "$(f "$T/linked" .branch)" '"wtb"'
eq "linked worktree root" "$(f "$T/linked" .repo_root)" "\"$(cd "$T/linked" && pwd -P)\""
eq "primary checkout is not linked" "$(f "$r" .linked_worktree)" false

# --- detached HEAD ---
r="$(mkrepo det)"; git -C "$r" checkout -q --detach
eq "detached branch null" "$(f "$r" .branch)" null
eq "detached flag" "$(f "$r" .detached)" true
eq "detached upstream null" "$(f "$r" .upstream)" null
eq "detached still has head" "$(f "$r" '.head != null')" true

# --- no commits yet ---
git init -q "$T/empty"
eq "empty repo exits 0" "$(bash "$script" --dir "$T/empty" >/dev/null 2>&1; echo $?)" 0
eq "empty repo head null" "$(f "$T/empty" .head)" null
eq "empty repo is not detached" "$(f "$T/empty" .detached)" false

# --- read-only ---
r="$(mkrepo ro)"; before="$(git -C "$r" status --porcelain; git -C "$r" rev-parse HEAD; ls -A "$r/.git" | md5sum)"
facts "$r" >/dev/null
eq "run leaves the repo unchanged" "$(git -C "$r" status --porcelain; git -C "$r" rev-parse HEAD; ls -A "$r/.git" | md5sum)" "$before"

# --- errors ---
mkdir "$T/plain-dir"
out="$(bash "$script" --dir "$T/plain-dir" 2>/dev/null)"; rc=$?
eq "non-repo exits 2" "$rc" 2
eq "non-repo json error" "$(jq -r .error <<<"$out")" "not a git repository"
eq "non-repo json dir" "$(jq -r .dir <<<"$out")" "$T/plain-dir"
out="$(bash "$script" --dir "$T/missing" 2>/dev/null)"; rc=$?
eq "missing dir exits 2" "$rc" 2
eq "missing dir json error" "$(jq -r 'has("error")' <<<"$out")" true
out="$(bash "$script" --bogus 2>/dev/null)"; rc=$?
eq "bad argument exits 2" "$rc" 2
eq "bad argument json error" "$(jq -r 'has("error")' <<<"$out")" true
out="$(bash "$script" --dir 2>/dev/null)"; rc=$?
eq "--dir without value exits 2" "$rc" 2

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
