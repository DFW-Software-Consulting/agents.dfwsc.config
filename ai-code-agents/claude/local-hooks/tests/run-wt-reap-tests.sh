#!/usr/bin/env bash
# CLI tests for bin/wt-reap (report first; --apply removes only when every safeguard holds, never forces).
# The seam is the command line: arguments, exit code, stdout, and what is left on disk afterwards
# (the worktree directory, the branch). Fixtures are real temporary git repositories made by this
# suite: a bare "remote", a main clone and linked worktrees. A fake `gh` first in the tool's gh search
# path (WT_REAP_TEST=1 + WT_REAP_GH_PATH) replays canned JSON per branch and records every argv. HOME and
# TMPDIR are throwaway. Shims first on PATH while the tool runs: a recording `git`, a recording `rm`, and a
# `timeout` that logs every gh the tool starts and blocks any gh but the fake (the tripwire against a real gh).
# Hermetic start: nothing inherited from the caller can change what the suite does, except the one
# documented override WT_REAP_SCRIPT (the script under test, for mutation proofs on a scratch copy).
# Usage: local-hooks/tests/run-wt-reap-tests.sh
set -uo pipefail
for _v in $(compgen -v); do case "$_v" in GH_*|GIT_*) unset "$_v" ;; esac; done
unset _v WT_REAP_TEST WT_REAP_GH_PATH BASH_ENV ENV GITHUB_TOKEN GITHUB_ENTERPRISE_TOKEN SHIM_BLOCK
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "$here/../.." && pwd)/bin/wt-reap"
if [ -n "${WT_REAP_SCRIPT:-}" ]; then
  if [ ! -f "$WT_REAP_SCRIPT" ] || [ ! -x "$WT_REAP_SCRIPT" ]; then
    echo "run-wt-reap-tests: WT_REAP_SCRIPT=$WT_REAP_SCRIPT is not an executable file; refusing to fall back" >&2; exit 2
  fi
  script="$(cd "$(dirname "$WT_REAP_SCRIPT")" && pwd)/$(basename "$WT_REAP_SCRIPT")"
fi
echo "wt-reap suite: script under test = $script"
tmp="$(mktemp -d)"; trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
export HOME="$tmp/home" TMPDIR="$tmp/tmp" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR"
git config --global user.name "Test User"; git config --global user.email "test@example.invalid"
git config --global init.defaultBranch main; git config --global commit.gpgsign false
git config --global core.excludesFile /dev/null; git config --global protocol.file.allow always
export XDG_CONFIG_HOME="$HOME/.config"
fx="$tmp/fx"; REPO="$fx/repo"; REMOTE="$fx/remote.git"; WTS="$fx/wts"
ghd="$tmp/ghfx"; GH_LOG="$ghd/calls.log"
REC_GIT_LOG="$tmp/git.log"; REC_RM_LOG="$tmp/rm.log"; GH_ALL="$tmp/gh-all.log"; SHIM_LOG="$tmp/timeout-shim.log"; US=$'\x1f'
cwd0="$tmp/cwd"; mkdir -p "$cwd0"

fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat >"$fakebin/gh" <<GH
#!/usr/bin/env bash
d="$ghd"; all="$GH_ALL"
GH
cat >>"$fakebin/gh" <<'GH'
US=$'\x1f'; line=""; for a in "$@"; do line+="$a$US"; done; printf '%s\n' "$line" >>"$d/calls.log"; printf '%s\n' "$line" >>"$all"
if [ -e "$d/env-probe" ]; then env >"$d/env.log"; fi
[ -e "$d/fail" ] && { echo "fake gh: simulated failure" >&2; exit 1; }
[ -e "$d/garbage" ] && { echo "this is not json"; exit 0; }
head=""; prev=""; for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
key="$(printf %s "$head" | sha1sum | cut -c1-12)"
n=$(( $(cat "$d/cnt.$key" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/cnt.$key"
[ -e "$d/hook.$key.$n" ] && bash "$d/hook.$key.$n"
[ -e "$d/failon.$key.$n" ] && { echo "fake gh: simulated failure on call $n" >&2; exit 1; }
f="$d/resp.$key.$n.json"; [ -e "$f" ] || f="$d/resp.$key.json"
[ -e "$f" ] || { echo "fake gh: no fixture for $head" >&2; exit 1; }
cat "$f"
GH
chmod +x "$fakebin/gh"
shim="$tmp/shim"; mkdir -p "$shim"
for tool in git rm; do
  logv=REC_GIT_LOG; [ "$tool" = rm ] && logv=REC_RM_LOG
  cat >"$shim/$tool" <<SH
#!/usr/bin/env bash
log="\${$logv:-/dev/null}"
SH
  cat >>"$shim/$tool" <<SH
line=""; for a in "\$@"; do line+="\$a\$(printf '\\037')"; done; printf '%s\\n' "\$line" >>"\$log"
exec /usr/bin/$tool "\$@"
SH
  chmod +x "$shim/$tool"
done
cat >"$shim/timeout" <<SH
#!/usr/bin/env bash
log="$SHIM_LOG"; fakegh="$fakebin/gh"
SH
cat >>"$shim/timeout" <<'SH'
isgh=0; allow=1
for a in "$@"; do
  case "$a" in gh) isgh=1 ;; */gh) isgh=1; [ "$a" = "$fakegh" ] || allow=0 ;; esac
done
if [ "$isgh" = 1 ]; then
  if [ "$allow" = 1 ]; then echo "exec $*" >>"$log"; else echo "block $*" >>"$log"; exit 1; fi
fi
exec /usr/bin/timeout "$@"
SH
chmod +x "$shim/timeout"
: >"$REC_GIT_LOG"; : >"$REC_RM_LOG"; : >"$SHIM_LOG"; : >"$GH_ALL"
export REC_GIT_LOG REC_RM_LOG

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
t() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
no() { ! "$@"; }
has() { grep -Fxq -- "$1" <<<"$out"; }
hasre() { grep -Eq -- "$1" <<<"$out"; }
branch_exists() { git -C "$REPO" show-ref --verify -q "refs/heads/$1"; }
keyof() { printf %s "$1" | sha1sum | cut -c1-12; }

# wr ARGS...: run the tool (cwd = $WR_CWD) with the shims, the fake gh and the test seam on
WR_CWD="$cwd0"
wr() { out="$(cd "$WR_CWD" && env PATH="$shim:$PATH" WT_REAP_TEST=1 WT_REAP_GH_PATH="$fakebin" bash "$script" "$@" 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"; }
# fixtures --------------------------------------------------------------------------------------
G() { git -C "$REPO" "$@"; }
newfx() {
  chmod -R u+rwX "$fx" 2>/dev/null; rm -rf "$fx" "$ghd"; mkdir -p "$fx" "$ghd" "$WTS"
  git init -q --bare "$REMOTE"; git clone -q "$REMOTE" "$REPO" 2>/dev/null
  echo base >"$REPO/README"; G add README; G commit -q -m base; G push -q -u origin main
  G remote set-head origin main
  printf '%s\n' '*.log' '*.pyc' 'node_modules/' '.env*' 'scratch-repo/' 'dist/' 'build/' 'venv/' '.venv/' '__pycache__/' '*.tmp' >>"$REPO/.git/info/exclude"
  : >"$GH_LOG"
}
# mkwt NAME BRANCH [nopush]: a linked worktree on BRANCH with one commit, pushed with upstream.
# The branch is made with update-ref + symbolic-ref so names git's own porcelain refuses (a leading
# dash) can still exist, which is the point.
mkwt() {
  local p="$WTS/$1" b="$2"
  G worktree add -q --detach "$p" main
  git -C "$p" update-ref "refs/heads/$b" HEAD; git -C "$p" symbolic-ref HEAD "refs/heads/$b"
  echo "$1" >"$p/$1.txt"; git -C "$p" add -- "$1.txt"; git -C "$p" commit -q -m "$1"
  [ "${3:-}" = nopush ] || git -C "$p" push -q -u origin "refs/heads/$b:refs/heads/$b"
}
tip() { G rev-parse "refs/heads/$1"; }
# ghsetb NAME NUMBER BASE [SHA]: one merged pull request whose base branch is BASE; ghset uses the default branch
ghsetb() { printf '[{"number":%s,"headRefOid":"%s","baseRefName":"%s"}]\n' "$2" "${4:-$(tip "$1")}" "$3" >"$ghd/resp.$(keyof "$1").json"; }
ghset() { ghsetb "$1" "$2" main "${3:-}"; }
ghnone() { echo '[]' >"$ghd/resp.$(keyof "$1").json"; }
snap() {
  { G worktree list --porcelain; G for-each-ref; G stash list
    (cd "$fx" && find . -path ./remote.git -prune -o ! -path '*/.git/*' -print0 | sort -z | xargs -0 -r sha256sum 2>&1)
    find "$REPO/.git/worktrees" "$REPO/.git/index" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
    find "$REPO/.git/worktrees" -type d | sort; } 2>&1
}
isroot() { [ "$(id -u)" = 0 ]; }

# 1. the big fixture: one worktree per case --------------------------------------------------------
BQ=$'q\'x"$(echo>MARK1);`echo>MARK2`'
build_big() {
  newfx
  mkwt ok feat-ok; ghset feat-ok 11
  mkwt meta feat-meta; echo '{}' >"$WTS/meta/.worktree-meta"; : >"$WTS/meta/a.pyc"; : >"$WTS/meta/b.pyc"; ghset feat-meta 12
  mkwt dirty feat-dirty; echo more >>"$WTS/dirty/dirty.txt"; ghset feat-dirty 13
  mkwt untr feat-untr; echo u >"$WTS/untr/u.txt"; ghset feat-untr 14
  mkwt staged feat-staged; echo s >"$WTS/staged/s.txt"; git -C "$WTS/staged" add s.txt; ghset feat-staged 15
  mkwt unp feat-unp; echo x >>"$WTS/unp/unp.txt"; git -C "$WTS/unp" commit -q -am more; ghset feat-unp 16
  mkwt noup feat-noup nopush; ghset feat-noup 17
  mkwt reused feat-reused; ghset feat-reused 18 1234567890123456789012345678901234567890
  mkwt open feat-open; ghnone feat-open
  mkwt feature-main feature-main; ghset feature-main 19
  G worktree add -q --detach "$WTS/detached" main
  G switch -q -c work
  G worktree add -q "$WTS/dflt" main; ghset main 20
  mkwt lock feat-lock; ghset feat-lock 21; G worktree lock "$WTS/lock"
  mkwt rb feat-rb; ghset feat-rb 22; mkdir "$(git -C "$WTS/rb" rev-parse --absolute-git-dir)/rebase-merge"
  mkwt mrg feat-mrg; ghset feat-mrg 23; : >"$(git -C "$WTS/mrg" rev-parse --absolute-git-dir)/MERGE_HEAD"
  mkwt stash feat-stash; echo z >>"$WTS/stash/stash.txt"; git -C "$WTS/stash" stash push -q; ghset feat-stash 24
  mkwt stash2 feat-stash2; ghset feat-stash2 25
  mkwt cwd feat-cwd; ghset feat-cwd 26
  mkwt cwd2 feat-cwd2; mkdir "$WTS/cwd2/sub"; echo s >"$WTS/cwd2/sub/f"; git -C "$WTS/cwd2" add sub/f; git -C "$WTS/cwd2" commit -q -m sub
  git -C "$WTS/cwd2" push -q; ghset feat-cwd2 27
  mkwt two feat-two
  printf '[{"headRefOid":"%s","number":30,"baseRefName":"main"},{"number":31,"headRefOid":"%s","baseRefName":"main"}]\n' 9999999999999999999999999999999999999999 "$(tip feat-two)" >"$ghd/resp.$(keyof feat-two).json"
  mkwt q "$BQ"; ghset "$BQ" 32
  mkwt dash --force; ghset --force 33
  mkwt dashdirty --delete; echo d >"$WTS/dashdirty/d.txt"; ghset --delete 34
}
line_removable() { echo "REMOVABLE $WTS/$1 $2 pr=$3"; }
line_keep() { echo "KEEP $WTS/$1 $2 $3"; }

build_big
before="$(snap)"
WR_CWD="$WTS/cwd"; wr --repo "$REPO"
rep_out="$out"; rep_rc=$rc
t "report: exit 0" test "$rep_rc" -eq 0
t "report: merged, clean, pushed, heads match is REMOVABLE" has "$(line_removable ok feat-ok 11)"
t "report: only .worktree-meta untracked is REMOVABLE, ignored files counted" has "$(line_removable meta feat-meta 12) ignored=2"
t "report: no ignored= suffix when nothing is ignored" no hasre 'feat-ok pr=11 ignored'
t "report: uncommitted change is KEEP" has "$(line_keep dirty feat-dirty 'uncommitted changes')"
t "report: untracked file is KEEP" has "$(line_keep untr feat-untr 'untracked files')"
t "report: staged change is KEEP" has "$(line_keep staged feat-staged 'uncommitted changes')"
t "report: unpushed commit is KEEP" has "$(line_keep unp feat-unp 'unpushed: local tip differs from upstream')"
t "report: no upstream is KEEP" has "$(line_keep noup feat-noup 'no upstream')"
t "report: reused branch name (merged PR head differs) is KEEP" has "$(line_keep reused feat-reused 'merged pull request head differs from branch tip')"
t "report: no merged pull request is KEEP" has "$(line_keep open feat-open 'no merged pull request')"
t "report: path ending in -main is KEEP" has "$(line_keep feature-main feature-main 'path ends in -main')"
t "report: the main working tree is KEEP" has "KEEP $REPO work main working tree"
t "report: detached HEAD is KEEP" has "$(line_keep detached '(detached)' 'detached HEAD')"
t "report: default branch is KEEP" has "$(line_keep dflt main 'default branch')"
t "report: locked is KEEP" has "$(line_keep lock feat-lock 'locked')"
t "report: rebase in progress is KEEP" has "$(line_keep rb feat-rb 'rebase in progress')"
t "report: merge in progress is KEEP" has "$(line_keep mrg feat-mrg 'merge in progress')"
t "report: a stash entry on the branch is KEEP" has "$(line_keep stash feat-stash 'stash entry references the branch')"
t "report: a stash on a branch whose name is a prefix does not block the longer name" has "$(line_removable stash2 feat-stash2 25)"
t "report: the worktree containing the current directory is KEEP" has "$(line_keep cwd feat-cwd 'current directory is inside it')"
t "report: a second merged PR with the matching head is found (any key order)" has "$(line_removable two feat-two 31)"
t "report: branch with quote, dollar, backtick and semicolon is REMOVABLE" has "$(line_removable q "$BQ" 32)"
t "report: branch named like an option (--force) is REMOVABLE" has "$(line_removable dash --force 33)"
t "report: a dirty branch named like an option (--delete) is KEEP" has "$(line_keep dashdirty --delete 'untracked files')"
t "report: prints the exact removal command" has "would run: git -C $REPO worktree remove -- $WTS/ok && git -C $REPO branch -d -- feat-ok"
t "report: the would-run command for a .worktree-meta worktree is plain (no temporary path)" has "would run: git -C $REPO worktree remove -- $WTS/meta && git -C $REPO branch -d -- feat-meta"
t "report: ...with one note saying .worktree-meta is treated as ignored for the removal" has "note: $WTS/meta: .worktree-meta is treated as ignored for this removal"
t "report: no temporary path or excludesFile appears in the report" no hasre 'core.excludesFile|exclude-worktree-meta'
t "report: gh was asked with --limit 100" grep -qF -- "--limit${US}100" "$GH_LOG"
t "report: summary line counts" has "wt-reap: 7 removable, 17 keep (report only; nothing changed)"
t "report: the quote branch never ran as code (no marker files)" test ! -e "$WR_CWD/MARK1" -a ! -e "$WR_CWD/MARK2" -a ! -e "$REPO/MARK1"
t "report mode changes nothing (worktrees, refs, stashes, file trees, indexes identical)" test "$before" = "$(snap)"

# the printed command is a faithful, runnable quoting (run it for the nastiest branch)
cmd_q="$(grep -F "branch -d -- " <<<"$rep_out" | grep -F 'MARK1' | sed 's/^would run: //')"
t "report: the printed command for the quoted branch runs as printed" bash -c 'test -n "$1" && eval "$1"' _ "$cmd_q"
t "report: ...and removed that worktree and branch" no test -d "$WTS/q"
t "report: ...and the branch is gone" no branch_exists "$BQ"
rm -f "$WR_CWD/MARK1" "$WR_CWD/MARK2"

# cwd inside a subdirectory of another worktree; the first one is then free
build_big; WR_CWD="$WTS/cwd2/sub"; wr
t "cwd in a subdirectory, no --repo: that worktree is KEEP" has "$(line_keep cwd2 feat-cwd2 'current directory is inside it')"
t "cwd in a subdirectory: another worktree is REMOVABLE" has "$(line_removable cwd feat-cwd 26)"
WR_CWD="$REPO"; wr
t "default repo is the one containing the current directory (main working tree)" has "$(line_removable ok feat-ok 11)"
WR_CWD="$cwd0"

# 2. --apply on the same kind of fixture -------------------------------------------------------------
build_big
WR_CWD="$WTS/cwd"; wr --repo "$REPO" --apply
t "apply: exit 0" test "$rc" -eq 0
t "apply: prints the removed worktrees with ignored counts" has "removed $WTS/ok feat-ok (ignored entries: 0, of which not dependency caches: 0)"
t "apply: summary" has "wt-reap: removed 7, failed 0, skipped 0, kept 17"
for c in "ok feat-ok" "meta feat-meta" "stash2 feat-stash2" "two feat-two" "q $BQ" "dash --force" "cwd2 feat-cwd2"; do
  n="${c%% *}"; b="${c#* }"
  t "apply: $n directory removed" no test -d "$WTS/$n"
  t "apply: $n branch removed" no branch_exists "$b"
done
for c in "dirty feat-dirty" "untr feat-untr" "staged feat-staged" "unp feat-unp" "noup feat-noup" "reused feat-reused" "open feat-open" \
         "feature-main feature-main" "detached" "dflt main" "lock feat-lock" "rb feat-rb" "mrg feat-mrg" "stash feat-stash" "cwd feat-cwd" "dashdirty --delete"; do
  n="${c%% *}"; b="${c#* }"
  t "apply: $n directory kept" test -d "$WTS/$n"
  [ "$c" = detached ] || t "apply: $n branch kept" branch_exists "$b"
done
t "apply: the main working tree is intact" test -f "$REPO/README"
t "apply: the dirty file is intact" grep -q more "$WTS/dirty/dirty.txt"
t "apply: the untracked file is intact" test -f "$WTS/untr/u.txt"
t "apply: the stash is intact" test "$(G stash list | wc -l)" -eq 1
t "apply: the quote branch never ran as code" test ! -e "$WR_CWD/MARK1" -a ! -e "$WR_CWD/MARK2" -a ! -e "$REPO/MARK1"
WR_CWD="$cwd0"

# 3. the re-check before acting (the fake gh changes the world between the report and the removal)
newfx
mkwt rc1 feat-rc1; ghset feat-rc1 41
printf 'echo late >"%s/rc1/late.txt"\n' "$WTS" >"$ghd/hook.$(keyof feat-rc1).1"
mkwt rc2 feat-rc2; ghset feat-rc2 42; echo '[]' >"$ghd/resp.$(keyof feat-rc2).2.json"
mkwt rc3 feat-rc3; ghset feat-rc3 43
wr --repo "$REPO" --apply
t "re-check: judged REMOVABLE first" has "$(line_removable rc1 feat-rc1 41)"
t "re-check: a file that appeared after the report is SKIPPED, not removed" hasre "^SKIPPED $WTS/rc1 feat-rc1: changed since the report: untracked files"
t "re-check: its directory and branch remain" test -d "$WTS/rc1" -a -f "$WTS/rc1/late.txt"
t "re-check: ...branch remains" branch_exists feat-rc1
t "re-check: a PR state that changed to none is SKIPPED" hasre "^SKIPPED $WTS/rc2 feat-rc2: changed since the report: no merged pull request"
t "re-check: ...its directory and branch remain" test -d "$WTS/rc2"
t "re-check: ...branch remains" branch_exists feat-rc2
t "re-check: an unchanged one is still removed" hasre "^removed $WTS/rc3 feat-rc3 "
t "re-check: skipped is not a failure (exit 0)" test "$rc" -eq 0
t "re-check: gh was asked twice for a removed worktree" test "$(grep -c -F "feat-rc3" "$GH_LOG")" -eq 2

# 4. gh unavailable: exit 10, nothing removed, in either mode
newfx; mkwt g1 feat-g1; ghset feat-g1 51
touch "$ghd/fail"
for mode in "" "--apply"; do
  wr --repo "$REPO" $mode
  t "gh error ${mode:-report}: exit 10" test "$rc" -eq 10
  t "gh error ${mode:-report}: message" test "$err" = "wt-reap: gh unavailable"
  t "gh error ${mode:-report}: nothing on stdout" test -z "$out"
  t "gh error ${mode:-report}: directory and branch remain" test -d "$WTS/g1"
  t "gh error ${mode:-report}: ...branch remains" branch_exists feat-g1
done
rm -f "$ghd/fail"; touch "$ghd/garbage"
wr --repo "$REPO" --apply
t "gh answering with non-JSON: exit 10 and nothing removed" test "$rc" -eq 10 -a -d "$WTS/g1"
rm -f "$ghd/garbage"
mkdir -p "$tmp/nogh"
for mode in "" "--apply"; do
  out="$(cd "$cwd0" && env PATH="$shim:$PATH" WT_REAP_TEST=1 WT_REAP_GH_PATH="$tmp/nogh" bash "$script" --repo "$REPO" $mode 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"
  t "gh missing ${mode:-report}: exit 10, message, nothing removed" test "$rc" -eq 10 -a "$err" = "wt-reap: gh unavailable" -a -d "$WTS/g1"
done
: >"$SHIM_LOG"; n0="$(wc -l <"$GH_LOG")"
out="$(cd "$cwd0" && env PATH="$shim:$PATH" WT_REAP_GH_PATH="$fakebin" bash "$script" --repo "$REPO" --apply 2>"$tmp/err")"; rc=$?
t "the gh path seam is ignored without WT_REAP_TEST=1 (the fake is not used, nothing removed)" test "$rc" -eq 10 -a -d "$WTS/g1" -a "$(wc -l <"$GH_LOG")" -eq "$n0"
t "...and the real gh was blocked by the tripwire, not run" grep -q '^block' "$SHIM_LOG"
: >"$SHIM_LOG"
touch "$ghd/env-probe"; export FOO_SECRET=leak; wr --repo "$REPO" --apply; unset FOO_SECRET
t "gh runs under a pinned environment (fixed PATH, no inherited variables)" bash -c '! grep -q FOO_SECRET "$1" && grep -qx "PATH=/usr/local/bin:/usr/bin:/bin" "$1"' _ "$ghd/env.log"
rm -f "$ghd/env-probe"

# 5. recovery: one removal fails, the others proceed
newfx
mkwt a1 feat-a1; ghset feat-a1 61
mkwt rf feat-rf; mkdir "$WTS/rf/sub"; echo f >"$WTS/rf/sub/f"; git -C "$WTS/rf" add sub/f; git -C "$WTS/rf" commit -q -m sub; git -C "$WTS/rf" push -q; ghset feat-rf 62
chmod 555 "$WTS/rf/sub"
mkwt z1 feat-z1; ghset feat-z1 63
if isroot; then echo "SKIP - removal failure: root ignores directory permissions"; else
  wr --repo "$REPO" --apply
  t "recovery: exit 1" test "$rc" -eq 1
  t "recovery: the failure is reported with git's error" hasre "^FAILED $WTS/rf feat-rf: git worktree remove failed: "
  t "recovery: the failed one is kept (directory)" test -d "$WTS/rf"
  t "recovery: ...and its branch" branch_exists feat-rf
  t "recovery: the one before it was removed" no test -d "$WTS/a1"
  t "recovery: the one after it was removed (and its branch)" no branch_exists feat-z1
  t "recovery: summary" has "wt-reap: removed 2, failed 1, skipped 0, kept 1"
  chmod 755 "$WTS/rf/sub"
fi

# 6. option handling, --json, a different repository
newfx; mkwt j1 feat-j1; ghset feat-j1 71; mkwt j2 feat-j2; echo m >>"$WTS/j2/j2.txt"; ghset feat-j2 72
wr --bogus; t "usage: unknown option exits 2" test "$rc" -eq 2
t "usage: names --include-ignored" grep -q -- "--include-ignored" <<<"$err"
wr --repo; t "usage: --repo without a value exits 2" test "$rc" -eq 2
wr --repo "$tmp/cwd"; t "usage: not a repository exits 2" test "$rc" -eq 2
wr --repo "$REPO" --json
t "json: one array, valid" bash -c 'jq -e "type == \"array\"" >/dev/null <<<"$1"' _ "$out"
t "json: REMOVABLE entry carries path, branch, pr and command" bash -c 'jq -e --arg p "$2/j1" ".[] | select(.path == \$p and .verdict == \"REMOVABLE\" and .branch == \"feat-j1\" and .pr == 71 and (.command | test(\"worktree remove\")))" >/dev/null <<<"$1"' _ "$out" "$WTS"
t "json: KEEP entry carries its reason" bash -c 'jq -e --arg p "$2/j2" ".[] | select(.path == \$p and .verdict == \"KEEP\" and .reason == \"uncommitted changes\")" >/dev/null <<<"$1"' _ "$out" "$WTS"
t "json: json mode changes nothing" test -d "$WTS/j1"
mkdir -p "$fx/other"; git init -q "$fx/other/r"; git -C "$fx/other/r" commit -q --allow-empty -m o
git -C "$fx/other/r" worktree add -q -b feat-other "$fx/other/wt"; ghset feat-other 99 "$(git -C "$fx/other/r" rev-parse feat-other)"
ob="$(git -C "$fx/other/r" worktree list --porcelain)"
wr --repo "$REPO" --apply --json
t "json --apply: result recorded per worktree (removed, and null for a kept one)" bash -c 'jq -e "(.[] | select(.branch == \"feat-j1\") | .result == \"removed\") and (.[] | select(.branch == \"feat-j2\") | .result == null)" >/dev/null <<<"$1"' _ "$out"
t "json --apply: nothing but JSON on stdout" bash -c 'jq -e . >/dev/null <<<"$1"' _ "$out"
t "another repository: its worktrees are untouched and gh never asked about them" test "$ob" = "$(git -C "$fx/other/r" worktree list --porcelain)" -a -d "$fx/other/wt" -a "$(grep -c feat-other "$GH_LOG")" -eq 0
t "git refuses a space in a branch name, so none can reach the tool" no git check-ref-format --branch 'a b'

# 8. ignored files (git worktree remove deletes them with the worktree) ----------------------------------
lnum() { grep -nFx -- "$1" <<<"$out" | head -1 | cut -d: -f1; }
build_ign() {
  newfx; rm -f "$XDG_CONFIG_HOME/wt-reap/ignorable"
  mkwt nm feat-nm; mkdir "$WTS/nm/node_modules"; : >"$WTS/nm/node_modules/p.js"; ghset feat-nm 81
  mkwt env feat-env; echo S=1 >"$WTS/env/.env"; ghset feat-env 82
  mkwt nest feat-nest; mkdir "$WTS/nest/scratch-repo"; git init -q "$WTS/nest/scratch-repo"; : >"$WTS/nest/scratch-repo/f"; ghset feat-nest 83
  mkwt gen feat-gen; echo g >"$WTS/gen/gen.tmp"; ghset feat-gen 84
}
SECRET_REASON='ignored files present (secret-looking, never removed): .env'
NM_RM="removing $WTS/nm (ignored entries: 1, of which not dependency caches: 0)"
build_ign; wr --repo "$REPO"
t "ignored: only node_modules/ ignored is REMOVABLE" has "$(line_removable nm feat-nm 81) ignored=1"
t "ignored: an ignored .env is KEEP and the reason names it" has "$(line_keep env feat-env "$SECRET_REASON")"
t "ignored: a non-dependency ignored file is KEEP, reason 'ignored files present'" has "$(line_keep gen feat-gen 'ignored files present (1): gen.tmp')"
t "ignored: a nested repository in an ignored path is KEEP" has "$(line_keep nest feat-nest 'nested repository in ignored path')"
wr --repo "$REPO" --json
t "ignored: json carries ignored and ignored_outside" bash -c 'jq -e ".[] | select(.branch == \"feat-env\") | (.ignored == 1 and .ignored_outside == 1)" >/dev/null <<<"$1"' _ "$out"
wr --repo "$REPO" --apply
t "ignored apply: node_modules worktree removed, announced first" test "$(lnum "$NM_RM")" -gt 0 -a "$(lnum "$NM_RM")" -lt "$(lnum "removed $WTS/nm feat-nm (ignored entries: 1, of which not dependency caches: 0)")"
t "ignored apply: node_modules worktree and branch gone" bash -c '[ ! -d "$1" ]' _ "$WTS/nm"
t "ignored apply: the .env worktree is kept with its file" test -f "$WTS/env/.env"
t "ignored apply: the gen.tmp worktree is kept with its file" test -f "$WTS/gen/gen.tmp"
t "ignored apply: ...and its branch" branch_exists feat-env
t "ignored apply: the nested repository survives" test -d "$WTS/nest/scratch-repo/.git"
build_ign; wr --repo "$REPO" --apply --include-ignored
t "include-ignored: gen.tmp worktree is REMOVABLE" has "$(line_removable gen feat-gen 84) ignored=1"
t "include-ignored: the report lists the ignored file before removal" has "  will delete ignored files (1): gen.tmp"
t "include-ignored: a secret-looking .env is still KEEP and named" has "$(line_keep env feat-env "$SECRET_REASON")"
E_RM="removing $WTS/gen (ignored entries: 1, of which not dependency caches: 1)"
t "include-ignored: the removing line (with counts) comes before the removed line" test "$(lnum "$E_RM")" -gt 0 -a "$(lnum "$E_RM")" -lt "$(lnum "removed $WTS/gen feat-gen (ignored entries: 1, of which not dependency caches: 1)")"
t "include-ignored: the gen.tmp worktree is removed" bash -c '[ ! -d "$1" ]' _ "$WTS/gen"
t "include-ignored: the .env worktree and its file survive" test -f "$WTS/env/.env"
t "include-ignored: a nested repository is still KEEP" has "$(line_keep nest feat-nest 'nested repository in ignored path')"
t "include-ignored: ...and survives" test -d "$WTS/nest/scratch-repo/.git"
build_ign; mkdir -p "$XDG_CONFIG_HOME/wt-reap"; printf '# comment\n\n.env*\n*.tmp\n' >"$XDG_CONFIG_HOME/wt-reap/ignorable"
wr --repo "$REPO"
t "owner file: *.tmp listed makes the gen.tmp worktree REMOVABLE" has "$(line_removable gen feat-gen 84) ignored=1"
t "owner file: .env* listed does not make a secret removable (still KEEP)" has "$(line_keep env feat-env "$SECRET_REASON")"
t "owner file: nested repository is still KEEP" has "$(line_keep nest feat-nest 'nested repository in ignored path')"
build_ign; mkdir -p "$XDG_CONFIG_HOME/wt-reap"; printf '$(touch MARKER)\n`touch MARKER`\n' >"$XDG_CONFIG_HOME/wt-reap/ignorable"
wr --repo "$REPO"
t "owner file: command text is only a glob (.env still KEEP)" has "$(line_keep env feat-env "$SECRET_REASON")"
t "owner file: command text is only a glob (gen.tmp still KEEP)" has "$(line_keep gen feat-gen 'ignored files present (1): gen.tmp')"
t "owner file: nothing executed (no marker file)" test ! -e "$cwd0/MARKER" -a ! -e "$REPO/MARKER" -a ! -e "$WTS/env/MARKER"
rm -f "$XDG_CONFIG_HOME/wt-reap/ignorable"

# 8b. ignored build outputs are inspected; dependency caches are not; secrets are never removed ---------------
build_ign2() {
  newfx; rm -f "$XDG_CONFIG_HOME/wt-reap/ignorable"
  mkwt dn feat-dn; mkdir "$WTS/dn/dist"; echo 'notes' >"$WTS/dn/dist/NOTES.txt"; ghset feat-dn 91
  mkwt dne feat-dne; mkdir "$WTS/dne/dist"; echo 'TOKEN=abc' >"$WTS/dne/dist/NOTES.env"; ghset feat-dne 98
  mkwt bo feat-bo; mkdir "$WTS/bo/build"; echo bin >"$WTS/bo/build/output.bin"; ghset feat-bo 92
  mkwt dep feat-dep; mkdir -p "$WTS/dep/node_modules/x" "$WTS/dep/.venv/lib" "$WTS/dep/__pycache__"; echo 'home = /usr' >"$WTS/dep/.venv/pyvenv.cfg"
  echo js >"$WTS/dep/node_modules/x/i.js"; echo py >"$WTS/dep/.venv/lib/a.py"; : >"$WTS/dep/__pycache__/m.pyc"; ghset feat-dep 93
  mkwt el feat-el; echo S=1 >"$WTS/el/.env.local"; ghset feat-el 94
  mkwt pk feat-pk; mkdir "$WTS/pk/dist"; echo k >"$WTS/pk/dist/server.key"; echo ok >"$WTS/pk/dist/a.js"; ghset feat-pk 95
}
build_ign2; b2="$(snap)"; wr --repo "$REPO"
t "build outputs: dist/NOTES.txt in a merged clean worktree is KEEP, 'ignored files present'" has "$(line_keep dn feat-dn 'ignored files present (1): dist/NOTES.txt')"
t "build outputs: dist/NOTES.env (matches *.env) is KEEP as secret-looking" has "$(line_keep dne feat-dne 'ignored files present (secret-looking, never removed): dist/NOTES.env')"
t "build outputs: build/output.bin alone is KEEP without --include-ignored" has "$(line_keep bo feat-bo 'ignored files present (1): build/output.bin')"
t "build outputs: node_modules, .venv and __pycache__ with files only is REMOVABLE" has "$(line_removable dep feat-dep 93) ignored=3"
t "build outputs: a secret-looking file in dist/ is KEEP and named (even though dist is a build output)" hasre "^KEEP $WTS/pk feat-pk ignored files present \(secret-looking, never removed\): dist/server.key"
t "build outputs: report mode removes nothing" test "$b2" = "$(snap)"
wr --repo "$REPO" --apply
t "build outputs apply: dist/NOTES.txt survives with its content" grep -q 'notes' "$WTS/dn/dist/NOTES.txt"
t "build outputs apply: dist/NOTES.env survives with its content" grep -q 'TOKEN=abc' "$WTS/dne/dist/NOTES.env"
t "build outputs apply: ...and its branch" branch_exists feat-dn
t "build outputs apply: build/output.bin survives" test -f "$WTS/bo/build/output.bin"
t "build outputs apply: the dependency-cache-only worktree and its branch are removed" bash -c '[ ! -d "$1" ]' _ "$WTS/dep"
t "build outputs apply: ...branch" no branch_exists feat-dep
t "build outputs apply: .env.local survives" test -f "$WTS/el/.env.local"
t "build outputs apply: dist/server.key survives" test -f "$WTS/pk/dist/server.key"
build_ign2; wr --repo "$REPO" --apply --include-ignored
t "build outputs include-ignored: build/output.bin worktree is REMOVABLE" has "$(line_removable bo feat-bo 92) ignored=1"
t "build outputs include-ignored: the report lists the count and the file before removal" has "  will delete ignored files (1): build/output.bin"
t "build outputs include-ignored: the listing comes before the removed line" test "$(lnum "  will delete ignored files (1): build/output.bin")" -gt 0 -a "$(lnum "  will delete ignored files (1): build/output.bin")" -lt "$(lnum "removed $WTS/bo feat-bo (ignored entries: 1, of which not dependency caches: 1)")"
t "build outputs include-ignored: build/output.bin worktree is removed" bash -c '[ ! -d "$1" ]' _ "$WTS/bo"
t "build outputs include-ignored: dist/NOTES.txt worktree is removed too" bash -c '[ ! -d "$1" ]' _ "$WTS/dn"
t "build outputs include-ignored: .env.local is KEEP and named" has "$(line_keep el feat-el 'ignored files present (secret-looking, never removed): .env.local')"
t "build outputs include-ignored: ...and survives" test -f "$WTS/el/.env.local"
t "build outputs include-ignored: dist/server.key is KEEP and survives" test -f "$WTS/pk/dist/server.key"
build_ign2; wr --repo "$REPO" --json --include-ignored
t "build outputs: json carries the ignored paths" bash -c 'jq -e ".[] | select(.branch == \"feat-bo\") | (.ignored_paths == [\"build/output.bin\"])" >/dev/null <<<"$1"' _ "$out"
build_ign2; mkdir "$WTS/dep/build"; mkdir -p "$WTS/dep/dist/node_modules/y"; : >"$WTS/dep/dist/node_modules/y/z.js"
wr --repo "$REPO"
t "build outputs: node_modules nested in dist/ is a dependency cache, not inspected" has "$(line_removable dep feat-dep 93) ignored=4"

# 8d. unreadable paths, secrets in caches, look-alike cache names, every secret pattern, links, the race ------------
build_r2() {
  newfx; rm -f "$XDG_CONFIG_HOME/wt-reap/ignorable"
  mkwt unr1 feat-unr1; mkdir -p "$WTS/unr1/node_modules/q" "$WTS/unr1/node_modules/ok"; : >"$WTS/unr1/node_modules/q/f"; ghset feat-unr1 201
  mkwt unr2 feat-unr2; mkdir -p "$WTS/unr2/build/sub"; : >"$WTS/unr2/build/sub/f"; ghset feat-unr2 202
  mkwt sec1 feat-sec1; mkdir -p "$WTS/sec1/node_modules/x"; echo S=1 >"$WTS/sec1/node_modules/x/.env"; ghset feat-sec1 203
  mkwt sec2 feat-sec2; mkdir -p "$WTS/sec2/.venv"; echo 'home = /usr' >"$WTS/sec2/.venv/pyvenv.cfg"; echo S=1 >"$WTS/sec2/.venv/.env"; ghset feat-sec2 204
  mkwt v1 feat-v1; mkdir "$WTS/v1/venv"; echo n >"$WTS/v1/venv/notes.txt"; ghset feat-v1 205
  mkwt v2 feat-v2; mkdir "$WTS/v2/venv"; echo 'home = /usr' >"$WTS/v2/venv/pyvenv.cfg"; echo n >"$WTS/v2/venv/lib.py"; ghset feat-v2 206
  mkwt v3 feat-v3; mkdir -p "$WTS/v3/build/sub/venv"; echo n >"$WTS/v3/build/sub/venv/notes.txt"; ghset feat-v3 207
  mkdir -p "$tmp/outside"; echo precious >"$tmp/outside/target.txt"
  mkwt lk feat-lk; mkdir "$WTS/lk/build"; ln -s "$tmp/outside/target.txt" "$WTS/lk/build/link"; ghset feat-lk 208
  if ! isroot; then chmod 000 "$WTS/unr1/node_modules/q" "$WTS/unr2/build/sub"; fi
}
if isroot; then echo "SKIP - unreadable directory cases: root ignores directory permissions"; fi
build_r2; wr --repo "$REPO"
if ! isroot; then
  t "unreadable: a directory inside node_modules is KEEP, not REMOVABLE" has "$(line_keep unr1 feat-unr1 'cannot read an ignored directory: node_modules/q')"
  t "unreadable: build/ holding only an unreadable subdirectory is KEEP, not REMOVABLE ignored=0" has "$(line_keep unr2 feat-unr2 'cannot read an ignored directory: build/sub')"
  wr --repo "$REPO" --apply --include-ignored
  t "unreadable apply: both worktrees remain" test -d "$WTS/unr1" -a -d "$WTS/unr2"
  chmod -R u+rwX "$WTS/unr1" "$WTS/unr2"; build_r2; wr --repo "$REPO"
fi
t "caches: a .env inside node_modules/x is KEEP and named" has "$(line_keep sec1 feat-sec1 'ignored files present (secret-looking, never removed): node_modules/x/.env')"
t "caches: a .env inside a real .venv is KEEP and named" has "$(line_keep sec2 feat-sec2 'ignored files present (secret-looking, never removed): .venv/.env')"
t "caches: a folder called venv without pyvenv.cfg is inspected (KEEP)" has "$(line_keep v1 feat-v1 'ignored files present (1): venv/notes.txt')"
t "caches: a venv with pyvenv.cfg is a cache (REMOVABLE)" has "$(line_removable v2 feat-v2 206) ignored=1"
t "caches: a look-alike venv nested in build/ is inspected (KEEP)" has "$(line_keep v3 feat-v3 'ignored files present (1): build/sub/venv/notes.txt')"
t "link: a symlink in an ignored dir counts as an ignored file (KEEP without the flag)" has "$(line_keep lk feat-lk 'ignored files present (1): build/link')"
wr --repo "$REPO" --apply --include-ignored
t "caches include-ignored: the .env in node_modules is still KEEP and survives" test -f "$WTS/sec1/node_modules/x/.env"
t "caches include-ignored: the .env in .venv is still KEEP and survives" test -f "$WTS/sec2/.venv/.env"
t "caches include-ignored: the look-alike venvs hold plain files, so the flag removes them (and only the flag)" bash -c '[ ! -d "$1/v1" ] && [ ! -d "$1/v3" ]' _ "$WTS"
t "caches include-ignored: the real venv worktree is removed" bash -c '[ ! -d "$1" ]' _ "$WTS/v2"
t "link include-ignored: the worktree with a symlink is removed" bash -c '[ ! -d "$1" ]' _ "$WTS/lk"
t "link include-ignored: the link target outside the worktree survives" grep -q precious "$tmp/outside/target.txt"

# every secret pattern, by name (case-insensitive) or by a parent directory, kept even with --include-ignored
newfx; rm -f "$XDG_CONFIG_HOME/wt-reap/ignorable"
npat=0; patnames=(.env .env.local prod.env PROD.ENV .envrc secrets.yml Secrets.json db-secret.json terraform.tfstate terraform.tfstate.backup .npmrc .pypirc .netrc .git-credentials server.pem a.key id_rsa a.p12 a.keystore credentials.json Credentials/a.json)
for n in "${patnames[@]}"; do
  npat=$((npat + 1)); mkwt "pat$npat" "feat-pat$npat"; mkdir -p "$WTS/pat$npat/build/$(dirname "$n")"; echo x >"$WTS/pat$npat/build/$n"; ghset "feat-pat$npat" $((300 + npat))
done
mkwt nearmiss feat-near; mkdir "$WTS/nearmiss/build"; echo x >"$WTS/nearmiss/build/my-secret.txt"; echo x >"$WTS/nearmiss/build/environment.txt"; ghset feat-near 399
wr --repo "$REPO" --include-ignored
npat=0
for n in "${patnames[@]}"; do
  npat=$((npat + 1))
  t "secret pattern: build/$n is KEEP even with --include-ignored" hasre "^KEEP $WTS/pat$npat feat-pat$npat ignored files present \(secret-looking, never removed\): "
done
t "secret pattern: a near miss (my-secret.txt, environment.txt) is not a secret, removable with the flag" has "$(line_removable nearmiss feat-near 399) ignored=1"
wr --repo "$REPO" --apply --include-ignored
t "secret pattern apply: every secret survives" bash -c 'n=0; for d in "$1"/pat*; do n=$((n+1)); done; [ "$n" -eq "$2" ]' _ "$WTS" "${#patnames[@]}"
t "secret pattern apply: the near-miss worktree is removed" bash -c '[ ! -d "$1" ]' _ "$WTS/nearmiss"

# a large node_modules is still quick: name-only scan, no file read
newfx; mkwt big feat-big; ghset feat-big 401
mkdir -p "$WTS/big/node_modules"
for d in $(seq 1 40); do mkdir "$WTS/big/node_modules/p$d"; (cd "$WTS/big/node_modules/p$d" && seq 1 100 | sed 's/^/f/' | xargs touch); done
nf="$(find "$WTS/big/node_modules" -type f | wc -l)"
t0=$(date +%s%N); wr --repo "$REPO"; t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
echo "info - report over a node_modules of $nf files took ${ms} ms"
t "large node_modules ($nf files): REMOVABLE" has "$(line_removable big feat-big 401) ignored=1"
t "large node_modules: the report took under 5 s (${ms} ms)" test "$ms" -lt 5000

# the race: files that appear after the ignored-file scan (during the gh lookup) must stop the removal
newfx
mkwt rc1 feat-race1; mkdir "$WTS/rc1/node_modules"; : >"$WTS/rc1/node_modules/p.js"; ghset feat-race1 411
printf 'mkdir -p "%s/rc1/dist"; echo late >"%s/rc1/dist/late.txt"\n' "$WTS" "$WTS" >"$ghd/hook.$(keyof feat-race1).2"
mkwt rc2 feat-race2; mkdir "$WTS/rc2/build"; echo a >"$WTS/rc2/build/a.bin"; ghset feat-race2 412
printf 'echo b >"%s/rc2/build/b.bin"\n' "$WTS" >"$ghd/hook.$(keyof feat-race2).2"
mkwt rc3 feat-race3; mkdir "$WTS/rc3/node_modules"; : >"$WTS/rc3/node_modules/p.js"; ghset feat-race3 413
printf 'echo S=1 >"%s/rc3/node_modules/.env"\n' "$WTS" >"$ghd/hook.$(keyof feat-race3).2"
mkwt rc4 feat-race4; mkdir "$WTS/rc4/node_modules"; : >"$WTS/rc4/node_modules/p.js"; ghset feat-race4 414
wr --repo "$REPO" --apply --include-ignored
t "race: an ignored file created after the scan is SKIPPED, not deleted" hasre "^SKIPPED $WTS/rc1 feat-race1: changed since the re-check: ignored files changed"
t "race: ...it survives" test -f "$WTS/rc1/dist/late.txt"
t "race: with --include-ignored, a changed set of ignored files is SKIPPED" hasre "^SKIPPED $WTS/rc2 feat-race2: changed since the re-check: ignored files changed"
t "race: ...both files survive" test -f "$WTS/rc2/build/a.bin" -a -f "$WTS/rc2/build/b.bin"
t "race: a secret created in a cache after the scan is SKIPPED" hasre "^SKIPPED $WTS/rc3 feat-race3: changed since the re-check: ignored files present \(secret-looking"
t "race: ...it survives" test -f "$WTS/rc3/node_modules/.env"
t "race: an untouched worktree is still removed" bash -c '[ ! -d "$1" ]' _ "$WTS/rc4"
t "race: skipped is not a failure (exit 0)" test "$rc" -eq 0

# the same race without the flag: the late file is reported as ignored files present
newfx; mkwt rc5 feat-race5; mkdir "$WTS/rc5/node_modules"; : >"$WTS/rc5/node_modules/p.js"; ghset feat-race5 415
printf 'mkdir -p "%s/rc5/dist"; echo late >"%s/rc5/dist/late.txt"\n' "$WTS" "$WTS" >"$ghd/hook.$(keyof feat-race5).2"
wr --repo "$REPO" --apply
t "race, no flag: a late ignored file is SKIPPED as ignored files present" hasre "^SKIPPED $WTS/rc5 feat-race5: changed since the re-check: ignored files present \(1\): dist/late.txt"
t "race, no flag: ...it survives" test -f "$WTS/rc5/dist/late.txt"

# 8c. a failing worktree listing during the re-check: nothing is removed, exit 10, the message says so
newfx; mkwt wl1 feat-wl1; ghset feat-wl1 96; mkwt wl2 feat-wl2; ghset feat-wl2 97
shimwl="$tmp/shimwl"; mkdir -p "$shimwl"; rm -f "$tmp/wl.count"
cat >"$shimwl/git" <<SH
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [ "\$prev" = worktree ] && [ "\$a" = list ]; then
    n=\$(( \$(cat "$tmp/wl.count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$tmp/wl.count"
    [ "\$n" -gt 1 ] && { echo "fake git: worktree list failed" >&2; exit 1; }
  fi
  prev="\$a"
done
exec "$shim/git" "\$@"
SH
chmod +x "$shimwl/git"
out="$(cd "$cwd0" && env PATH="$shimwl:$shim:$PATH" WT_REAP_TEST=1 WT_REAP_GH_PATH="$fakebin" bash "$script" --repo "$REPO" --apply 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"
t "listing fails in the re-check: both were judged REMOVABLE first" test "$(grep -c '^REMOVABLE' <<<"$out")" -eq 2
t "listing fails in the re-check: exit 10" test "$rc" -eq 10
t "listing fails in the re-check: the message says the listing failed" grep -q 'wt-reap: git worktree list failed' <<<"$err"
t "listing fails in the re-check: each is SKIPPED with the reason" hasre "^SKIPPED $WTS/wl1 feat-wl1: git worktree list failed during the re-check"
t "listing fails in the re-check: ...also the later one" hasre "^SKIPPED $WTS/wl2 feat-wl2: git worktree list failed during the re-check"
t "listing fails in the re-check: nothing removed (directories)" test -d "$WTS/wl1" -a -d "$WTS/wl2"
t "listing fails in the re-check: nothing removed (branches)" bash -c 'git -C "$1" show-ref --verify -q refs/heads/feat-wl1 && git -C "$1" show-ref --verify -q refs/heads/feat-wl2' _ "$REPO"
t "listing fails in the re-check: summary counts them as skipped" has "wt-reap: removed 0, failed 0, skipped 2, kept 1"

# 9. a later gh failure during the re-check: earlier removals are reported, the rest SKIPPED, exit 10
newfx
mkwt r1 feat-r1; ghset feat-r1 101
mkwt r2 feat-r2; ghset feat-r2 102; touch "$ghd/failon.$(keyof feat-r2).2"
mkwt r3 feat-r3; ghset feat-r3 103
wr --repo "$REPO" --apply
t "re-check gh failure: exit 10" test "$rc" -eq 10
t "re-check gh failure: stderr says gh unavailable" test "$err" = "wt-reap: gh unavailable"
t "re-check gh failure: the earlier removal is listed" hasre "^removed $WTS/r1 feat-r1 "
t "re-check gh failure: the earlier worktree is really gone" bash -c '[ ! -d "$1" ]' _ "$WTS/r1"
t "re-check gh failure: the failing one is SKIPPED with the reason" hasre "^SKIPPED $WTS/r2 feat-r2: gh unavailable during the re-check"
t "re-check gh failure: the remaining one is SKIPPED too" hasre "^SKIPPED $WTS/r3 feat-r3: gh unavailable during the re-check"
t "re-check gh failure: both are kept on disk" test -d "$WTS/r2" -a -d "$WTS/r3"
t "re-check gh failure: summary line is printed" hasre '^wt-reap: removed 1, failed 0, skipped 2, kept 1'

# 10. a dirty submodule must not be hidden by diff.ignoreSubmodules
newfx
git init -q "$fx/subrepo"; echo s >"$fx/subrepo/s"; git -C "$fx/subrepo" add s; git -C "$fx/subrepo" commit -q -m s
mkwt sm feat-sm; git -C "$WTS/sm" submodule -q add "$fx/subrepo" sub; git -C "$WTS/sm" commit -q -m sub; git -C "$WTS/sm" push -q
G config diff.ignoreSubmodules all; echo dirty >>"$WTS/sm/sub/s"; ghset feat-sm 111
t "submodule fixture: plain git status is blind to the dirty submodule" test -z "$(git -C "$WTS/sm" status --porcelain)"
wr --repo "$REPO"
t "submodule: a dirty submodule makes the worktree KEEP" has "$(line_keep sm feat-sm 'uncommitted changes')"

# 11. upstream gone after a merge
newfx
mkwt g1 feat-g1; ghset feat-g1 121
mkwt g2 feat-g2; ghset feat-g2 122 1234567890123456789012345678901234567890
mkwt g3 feat-g3; ghset feat-g3 123; echo more >>"$WTS/g3/g3.txt"; git -C "$WTS/g3" commit -q -am extra
mkwt g4 feat-g4; ghnone feat-g4
mkwt nup2 feat-nup2 nopush; ghset feat-nup2 125
for b in feat-g1 feat-g2 feat-g3 feat-g4; do git -C "$REMOTE" update-ref -d "refs/heads/$b"; done
G fetch -q --prune
G_TIP="$(tip feat-g1)"
wr --repo "$REPO"
t "upstream gone: matching merged head is REMOVABLE (and says so)" has "$(line_removable g1 feat-g1 121) upstream=gone"
t "upstream gone: non-matching merged head is KEEP" has "$(line_keep g2 feat-g2 'upstream gone: merged pull request head differs from branch tip')"
t "upstream gone: one extra local commit is KEEP" has "$(line_keep g3 feat-g3 'upstream gone: merged pull request head differs from branch tip')"
t "upstream gone: no merged pull request is KEEP" has "$(line_keep g4 feat-g4 'upstream gone: no merged pull request')"
t "upstream never configured is still KEEP no upstream" has "$(line_keep nup2 feat-nup2 'no upstream')"
wr --repo "$REPO" --apply
t "upstream gone apply: exit 0 (a kept branch is not a failed removal)" test "$rc" -eq 0
t "upstream gone apply: the worktree is removed" bash -c '[ ! -d "$1" ]' _ "$WTS/g1"
t "upstream gone apply: the branch is kept (never -D)" branch_exists feat-g1
t "upstream gone apply: says so, with the tip and the pull request" has "worktree removed; branch feat-g1 kept (git does not see it as merged; its tip $G_TIP is the head of merged pull request #121)"
t "upstream gone apply: the other three are untouched" test -d "$WTS/g2" -a -d "$WTS/g3" -a -d "$WTS/g4"
t "upstream gone apply: summary counts the removal" hasre '^wt-reap: removed 1, failed 0, skipped 0, kept '

# 12. index flags that hide edits from git status (assume-unchanged, skip-worktree) ---------------------
HID='index flags hide changes (assume-unchanged or skip-worktree)'
newfx
mkwt ac feat-ac; ghset feat-ac 131; git -C "$WTS/ac" update-index --assume-unchanged ac.txt; echo hidden >>"$WTS/ac/ac.txt"
mkwt acc feat-acc; ghset feat-acc 132
mkwt sw feat-sw; ghset feat-sw 133; git -C "$WTS/sw" update-index --skip-worktree sw.txt; echo hidden >>"$WTS/sw/sw.txt"
mkwt swc feat-swc; ghset feat-swc 134
mkwt lf feat-lf; ghset feat-lf 136
t "flags fixture: plain git status is blind to the assume-unchanged edit" test -z "$(git -C "$WTS/ac" status --porcelain)"
t "flags fixture: plain git status is blind to the skip-worktree edit" test -z "$(git -C "$WTS/sw" status --porcelain)"
wr --repo "$REPO"
t "flags: assume-unchanged edit is KEEP with the new reason" has "$(line_keep ac feat-ac "$HID")"
t "flags: control without the hidden edit is REMOVABLE (assume-unchanged case)" has "$(line_removable acc feat-acc 132)"
t "flags: skip-worktree edit is KEEP with the new reason" has "$(line_keep sw feat-sw "$HID")"
t "flags: control without the hidden edit is REMOVABLE (skip-worktree case)" has "$(line_removable swc feat-swc 134)"
t "flags: a failing index listing is not what kept them (listing works in this run)" no hasre 'index listing failed'
# a shim that fails only the ls-files call
shimls="$tmp/shimls"; mkdir -p "$shimls"
cat >"$shimls/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = ls-files ] && { echo "fake git: ls-files failed" >&2; exit 1; }; done
exec "$shim/git" "\$@"
SH
chmod +x "$shimls/git"
out="$(cd "$cwd0" && env PATH="$shimls:$shim:$PATH" WT_REAP_TEST=1 WT_REAP_GH_PATH="$fakebin" bash "$script" --repo "$REPO" 2>"$tmp/err")"; rc=$?
t "listing fails: the otherwise removable worktree is KEEP with the distinct reason" has "$(line_keep lf feat-lf 'git error: index listing failed')"
wr --repo "$REPO"
t "listing fails: control, same worktree with a working git is REMOVABLE" has "$(line_removable lf feat-lf 136)"
wr --repo "$REPO" --apply
t "flags apply: the hidden edits survive (assume-unchanged)" grep -q hidden "$WTS/ac/ac.txt"
t "flags apply: the hidden edits survive (skip-worktree)" grep -q hidden "$WTS/sw/sw.txt"
t "flags apply: the controls were removed" no test -d "$WTS/acc" -o -d "$WTS/swc"
newfx; mkwt late feat-late; ghset feat-late 135
printf 'git -C "%s/late" update-index --assume-unchanged late.txt; echo hidden >>"%s/late/late.txt"\n' "$WTS" "$WTS" >"$ghd/hook.$(keyof feat-late).2"
wr --repo "$REPO" --apply
t "flags apply: a flag set between the report and the removal is SKIPPED by the re-check" hasre "^SKIPPED $WTS/late feat-late: changed since the report: index flags hide changes"
t "flags apply: ...and its directory with the edit remains" grep -q hidden "$WTS/late/late.txt"

# 13. the base of the merged pull request must be the default branch
newfx
mkwt nb feat-nb; ghsetb feat-nb 141 develop
mkwt nbg feat-nbg; ghsetb feat-nbg 142 develop; git -C "$REMOTE" update-ref -d refs/heads/feat-nbg
mkwt abs feat-abs; printf '[{"number":143,"headRefOid":"%s"}]\n' "$(tip feat-abs)" >"$ghd/resp.$(keyof feat-abs).json"
mkwt emp feat-emp; ghsetb feat-emp 144 ""
mkwt o1 feat-o1; printf '[{"number":145,"headRefOid":"%s","baseRefName":"main"},{"number":146,"headRefOid":"%s","baseRefName":"develop"}]\n' "$(tip feat-o1)" "$(tip feat-o1)" >"$ghd/resp.$(keyof feat-o1).json"
mkwt o2 feat-o2; printf '[{"number":148,"headRefOid":"%s","baseRefName":"develop"},{"number":147,"headRefOid":"%s","baseRefName":"main"}]\n' "$(tip feat-o2)" "$(tip feat-o2)" >"$ghd/resp.$(keyof feat-o2).json"
mkwt ok2 feat-ok2; ghset feat-ok2 149
G fetch -q --prune
wr --repo "$REPO"
t "base: merged into a non-default base is KEEP with its own reason" has "$(line_keep nb feat-nb 'merged into a non-default base')"
t "base: ...also when the upstream is gone" has "$(line_keep nbg feat-nbg 'upstream gone: merged into a non-default base')"
t "base: a missing baseRefName does not qualify (KEEP, own reason)" has "$(line_keep abs feat-abs 'merged pull request has no base branch')"
t "base: an empty baseRefName does not qualify (KEEP, own reason)" has "$(line_keep emp feat-emp 'merged pull request has no base branch')"
t "base: two PRs with the same head, default base first, is REMOVABLE with that PR" has "$(line_removable o1 feat-o1 145)"
t "base: two PRs with the same head, default base second, is REMOVABLE with that PR" has "$(line_removable o2 feat-o2 147)"
t "base: a PR into the default branch is REMOVABLE" has "$(line_removable ok2 feat-ok2 149)"
t "base: gh was asked for baseRefName" grep -qF -- "number,headRefOid,baseRefName" "$GH_LOG"
G remote set-head origin -d
wr --repo "$REPO"
t "base: origin/HEAD unset is KEEP and the reason says how to set it" has "$(line_keep ok2 feat-ok2 'origin/HEAD is not set (run: git remote set-head origin --auto)')"
G remote set-head origin main

# 14. more stash, path and symlink cases
newfx
mkwt st3 feat-st3; echo z >>"$WTS/st3/st3.txt"; git -C "$WTS/st3" stash push -q -m "saved work"; ghset feat-st3 151
mkwt "sp ace" feat-sp; ghset feat-sp 152
mkwt sl feat-sl; ghset feat-sl 153
ln -s "$WTS/sl" "$tmp/sl-link"
mkwt ok3 feat-ok3; ghset feat-ok3 154
t "stash fixture: the entry has the 'On <branch>:' form" bash -c 'G=$(git -C "$1" stash list --format=%gs); [ "$G" = "On feat-st3: saved work" ]' _ "$REPO"
wr --repo "$REPO"
t "stash: the 'On <branch>:' form is KEEP" has "$(line_keep st3 feat-st3 'stash entry references the branch')"
t "path with a space: REMOVABLE" has "$(line_removable 'sp ace' feat-sp 152)"
t "path with a space: the other paths are unaffected" has "$(line_removable ok3 feat-ok3 154)"
WR_CWD="$tmp/sl-link"; wr --repo "$REPO"
t "symlinked path: a current directory reached through a symlink is KEEP" has "$(line_keep sl feat-sl 'current directory is inside it')"
WR_CWD="$cwd0"
wr --repo "$REPO" --apply
t "path with a space apply: removed" no test -d "$WTS/sp ace"
t "stash apply: the worktree with the stash is kept" test -d "$WTS/st3"

# 15. origin/HEAD present only as a plain commit ref (not a symbolic ref): the default branch is unknown
newfx
G push -q origin main:develop; git -C "$REMOTE" symbolic-ref HEAD refs/heads/develop
G remote set-head origin -d; G update-ref refs/remotes/origin/HEAD "$(G rev-parse refs/remotes/origin/main)"
mkwt pr1 feat-pr1; ghset feat-pr1 161
t "plain-ref fixture: origin/HEAD resolves but is not a symbolic ref" bash -c 'git -C "$1" rev-parse --verify -q refs/remotes/origin/HEAD >/dev/null && ! git -C "$1" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null' _ "$REPO"
wr --repo "$REPO"
t "plain-ref origin/HEAD: a merged PR into the guessed main is KEEP with the unset reason" has "$(line_keep pr1 feat-pr1 'origin/HEAD is not set (run: git remote set-head origin --auto)')"
G update-ref -d refs/remotes/origin/HEAD; G remote set-head origin develop
wr --repo "$REPO"
t "plain-ref control: a real symbolic origin/HEAD on develop makes the main-based PR KEEP as non-default" has "$(line_keep pr1 feat-pr1 'merged into a non-default base')"

# 7. whole-suite checks over what the tool ran ---------------------------------------------------------
bad_flags="$(awk -F "$US" '{
  scan = 0; for (i = 1; i <= NF; i++) { if ($i == "--") break; if (($i == "worktree" && $(i + 1) == "remove") || $i == "branch") scan = 1 }
  if (scan) for (i = 1; i <= NF; i++) { if ($i == "--") break; if ($i == "--force" || $i ~ /^-[a-zA-Z]*[fD][a-zA-Z]*$/) print $0 }
}' "$REC_GIT_LOG")"
t "git was never passed --force, -f or -D for a worktree or branch removal" test -z "$bad_flags"
t "...and removals were recorded at all (the check is not vacuous)" bash -c 'grep -q "worktree.remove" "$1" && grep -q "branch.-d" "$1"' _ "$REC_GIT_LOG"
t "rm was only used inside the tool's own temporary directory" bash -c '! grep -v -F "$2" "$1" | grep -q .' _ "$REC_RM_LOG" "$TMPDIR/"
t "the fake gh log contains only pr list calls (whole suite)" bash -c '! grep -v "^pr${2}list${2}" "$1" | grep -q . && [ -s "$1" ]' _ "$GH_ALL" "$US"
t "every gh run went through the fake (the tripwire blocked nothing)" bash -c '! grep -q "^block" "$1" && grep -q "^exec" "$1"' _ "$SHIM_LOG"
echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
