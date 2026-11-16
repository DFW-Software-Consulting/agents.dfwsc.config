#!/usr/bin/env bash
# Tests for run-checks.sh, _run_checks.py and _checks_stamp.py.
# Builds throwaway repos under a temp dir with a temporary HOME. Needs no npm,
# network or toolchain: real runs use .claude/git-checks files of plain shell
# commands; package.json detection is tested by calling the library directly.
# Usage: local-hooks/tests/run-checks-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
unset CLAUDE_CHECKS_TIMEOUT
rc_script="$hooks/run-checks.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

T="$(mktemp -d "$HOME/t.XXXXXX")"
lib() { python3 -I -c "
import sys,json; sys.path.insert(0,'$hooks'); import _checks_stamp as c
$1"; }
detect() { lib "print(json.dumps(c.detect_commands('$1', $2)))"; }

# mkrepo NAME [CHECKS]  (committed repo; CHECKS becomes .claude/git-checks)
mkrepo() {
  local d="$T/$1"; git init -q "$d"; echo a > "$d/a.txt"
  if [ -n "${2:-}" ]; then mkdir -p "$d/.claude"; printf '%s\n' "$2" > "$d/.claude/git-checks"; fi
  git -C "$d" add -A; git -C "$d" commit -qm init; echo "$d"
}
run() { bash "$rc_script" "$@" 2>/dev/null; }

# --- detection ---
d="$T/det1"; mkdir -p "$d/.claude"; printf '# c\n\n  echo one  \n#x\necho two\n' > "$d/.claude/git-checks"
echo '{"scripts":{"lint":"x"}}' > "$d/package.json"
eq "explicit file wins, comments/blanks ignored" "$(detect "$d" False)" '["echo one", "echo two"]'
d="$T/det2"; mkdir "$d"; echo '{"scripts":{"test":"jest","lint":"l","typecheck":"t","build":"b"}}' > "$d/package.json"
eq "package.json typecheck, lint, test in order" "$(detect "$d" False)" '["npm run typecheck", "npm run lint", "npm run test"]'
eq "build only with flag" "$(detect "$d" True)" '["npm run typecheck", "npm run lint", "npm run test", "npm run build"]'
d="$T/det3"; mkdir "$d"; echo '{"scripts":{"type-check":"t"}}' > "$d/package.json"
eq "type-check script detected" "$(detect "$d" False)" '["npm run type-check"]'
d="$T/det4"; mkdir "$d"; echo '{"scripts":{"lint":"l"}}' > "$d/package.json"
eq "lint only" "$(detect "$d" False)" '["npm run lint"]'
d="$T/det5"; mkdir "$d"; echo '{"scripts":{"test":"jest"}}' > "$d/package.json"
eq "test only" "$(detect "$d" False)" '["npm run test"]'
d="$T/det6"; mkdir "$d"; echo '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}' > "$d/package.json"
eq "npm placeholder test skipped" "$(detect "$d" False)" '[]'
for pair in "pnpm-lock.yaml:pnpm" "yarn.lock:yarn" "bun.lockb:bun" "bun.lock:bun" "package-lock.json:npm"; do
  f="${pair%%:*}"; pm="${pair##*:}"; d="$T/pm-$f"; mkdir "$d"
  echo '{"scripts":{"lint":"l"}}' > "$d/package.json"; : > "$d/$f"
  eq "lockfile $f picks $pm" "$(detect "$d" False)" "[\"$pm run lint\"]"
done
d="$T/det7"; mkdir "$d"; eq "no files gives empty list" "$(detect "$d" False)" '[]'
d="$T/det8"; mkdir "$d"; echo 'not json' > "$d/package.json"; eq "invalid package.json gives empty list" "$(detect "$d" False)" '[]'

# --- passing run ---
r="$(mkrepo pass $'echo build-ok\ntrue')"
head="$(git -C "$r" rev-parse HEAD)"; tree="$(git -C "$r" rev-parse HEAD^{tree})"
out="$(run --dir "$r")"; rc=$?
eq "passing run exits 0" "$rc" 0
eq "passing run status" "$(jq -r .status <<<"$out")" passed
eq "output head" "$(jq -r .head <<<"$out")" "$head"
eq "output tree" "$(jq -r .tree <<<"$out")" "$tree"
sp="$(jq -r .stamp <<<"$out")"
eq "stamp path is in the git dir" "$sp" "$r/.git/claude-checks/$head.json"
eq "stamp status passed" "$(jq -r .status "$sp")" passed
eq "stamp head" "$(jq -r .head "$sp")" "$head"
eq "stamp tree" "$(jq -r .tree "$sp")" "$tree"
eq "stamp version" "$(jq -r .version "$sp")" 1
eq "stamp ts is ISO 8601 UTC" "$(jq -r .ts "$sp" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$')" 1
eq "stamp detected" "$(jq -c .detected "$sp")" '["echo build-ok","true"]'
eq "stamp results have cmd/exit/seconds" "$(jq -c '[.results[]|keys]|unique' "$sp")" '[["cmd","exit","seconds"]]'
eq "stdout is exactly one JSON object" "$(printf '%s\n' "$out" | wc -l)" 1
eq "result carries the tail" "$(jq -r '.results[0].tail' <<<"$out")" build-ok
eq "stamp not shown as untracked" "$(git -C "$r" status --porcelain | wc -l)" 0
eq "stamp validates for head" "$(lib "
s=c.read_stamp('$sp'); print(c.stamp_valid(s,'$head',c.detect_commands('$r')))")" True

# --- failing run ---
r="$(mkrepo fail $'echo first > ran1\nsh -c "echo boom; exit 3"\necho third > ran3')"
out="$(run --dir "$r")"; rc=$?
eq "failing run exits 1" "$rc" 1
eq "failing run status" "$(jq -r .status <<<"$out")" failed
eq "failing command exit recorded" "$(jq -c '[.results[].exit]' <<<"$out")" '[0,3,0]'
eq "later commands still ran" "$(cat "$r/ran3" 2>/dev/null)" third
eq "stamp status failed" "$(jq -r .status "$(jq -r .stamp <<<"$out")")" failed
eq "failed stamp does not validate" "$(lib "
h='$(git -C "$r" rev-parse HEAD)'; s=c.read_stamp(c.stamp_path('$r/.git',h)); print(c.stamp_valid(s,h,[]))")" False

# --- none detected ---
r="$(mkrepo none)"
out="$(run --dir "$r")"; rc=$?
eq "none detected exits 0" "$rc" 0
eq "none detected status" "$(jq -r .status <<<"$out")" none_detected
eq "none detected stamp written" "$(jq -r .status "$(jq -r .stamp <<<"$out")")" none_detected

# --- dirty / untracked ---
r="$(mkrepo dirty 'true')"; echo change >> "$r/a.txt"
out="$(run --dir "$r")"; rc=$?
eq "dirty tracked file exits 3" "$rc" 3
eq "dirty status" "$(jq -r .status <<<"$out")" dirty
eq "dirty lists the path" "$(jq -r '.dirty[0]' <<<"$out")" a.txt
eq "dirty writes no stamp" "$(ls "$r/.git/claude-checks" 2>/dev/null | wc -l)" 0
r="$(mkrepo untracked 'true')"; echo new > "$r/new.txt"
run --dir "$r" >/dev/null; eq "untracked file alone is not dirty" "$?" 0
r="$(mkrepo manydirty 'true')"; for i in $(seq 1 25); do echo x > "$r/f$i"; done
git -C "$r" add -A; git -C "$r" commit -qm more; for i in $(seq 1 25); do echo y >> "$r/f$i"; done
out="$(run --dir "$r")"; eq "dirty paths capped at 20" "$(jq '.dirty|length' <<<"$out")" 20

# --- not a repo / unborn ---
mkdir "$T/plain"; out="$(run --dir "$T/plain")"; rc=$?
eq "not a repo exits 2" "$rc" 2; eq "not a repo prints JSON error" "$(jq -r .status <<<"$out")" error
git init -q "$T/unborn"; out="$(run --dir "$T/unborn")"; rc=$?
eq "unborn repo exits 2" "$rc" 2; eq "unborn prints JSON error" "$(jq -r .status <<<"$out")" error

# --- timeout ---
r="$(mkrepo slow $'sleep 5\ntrue')"
s0=$SECONDS; out="$(CLAUDE_CHECKS_TIMEOUT=1 run --dir "$r")"; rc=$?
eq "timeout recorded as 124" "$(jq -c '[.results[].exit]' <<<"$out")" '[124,0]'
eq "timeout run exits 1" "$rc" 1
[ $((SECONDS - s0)) -lt 5 ] && ok "timeout cut the command short" || bad "timeout cut the command short"

# --- tail ---
r="$(mkrepo tail 'seq 1 100')"
out="$(run --dir "$r")"
eq "tail holds at most 40 lines" "$(jq -r '.results[0].tail' <<<"$out" | wc -l)" 40
eq "tail is the last lines" "$(jq -r '.results[0].tail' <<<"$out" | tail -1)" 100
r="$(mkrepo tailerr 'echo out; echo err >&2')"
out="$(run --dir "$r")"; eq "tail combines stdout and stderr" "$(jq -r '.results[0].tail' <<<"$out" | sort | tr '\n' ' ')" "err out "

# --- stdin, quotes and pipe ---
r="$(mkrepo stdin $'[ -z "$(cat)" ]')"
out="$(run --dir "$r" </dev/zero | head -c 100000)"; eq "command stdin is /dev/null" "$(jq -r .status <<<"$out")" passed
r="$(mkrepo quote $'echo \'a "b" c\' | grep -q \'"b"\' && echo found | tr a-z A-Z')"
out="$(run --dir "$r")"
eq "quotes and pipe run correctly" "$(jq -r '.status+" "+.results[0].tail' <<<"$out")" "passed FOUND"

# --- staleness ---
r="$(mkrepo stale 'true')"; h1="$(git -C "$r" rev-parse HEAD)"
run --dir "$r" >/dev/null
echo b > "$r/b.txt"; git -C "$r" add -A; git -C "$r" commit -qm two; h2="$(git -C "$r" rev-parse HEAD)"
eq "old stamp does not validate for a new head" "$(lib "
s=c.read_stamp(c.stamp_path('$r/.git','$h1')); print(c.stamp_valid(s,'$h2',c.detect_commands('$r')))")" False
eq "no stamp for the new head reads as None" "$(lib "print(c.read_stamp(c.stamp_path('$r/.git','$h2')))")" None
echo 'echo extra' >> "$r/.claude/git-checks"; git -C "$r" commit -qam three
run --dir "$r" >/dev/null; h3="$(git -C "$r" rev-parse HEAD)"
echo 'echo another' >> "$r/.claude/git-checks"
eq "adding a command invalidates an old stamp" "$(lib "
s=c.read_stamp(c.stamp_path('$r/.git','$h3')); print(c.stamp_valid(s,'$h3',c.detect_commands('$r')))")" False
eq "stamp_valid(None) is False" "$(lib "print(c.stamp_valid(None,'x',[]))")" False
eq "stamp_valid wrong head is False" "$(lib "
print(c.stamp_valid({'head':'a','status':'passed','results':[],'detected':[]},'b',[]))")" False
eq "stamp_valid nonzero result is False" "$(lib "
print(c.stamp_valid({'head':'a','status':'passed','results':[{'exit':1}],'detected':[]},'a',[]))")" False
eq "stamp_valid none_detected ok" "$(lib "
print(c.stamp_valid({'head':'a','status':'none_detected','results':[],'detected':[]},'a',[]))")" True

# --- corrupt / missing / wrong version ---
printf '{not json' > "$T/corrupt.json"; echo '{"version":2,"head":"a"}' > "$T/v2.json"
eq "corrupt stamp reads as None" "$(lib "print(c.read_stamp('$T/corrupt.json'))")" None
eq "wrong version reads as None" "$(lib "print(c.read_stamp('$T/v2.json'))")" None
eq "missing stamp reads as None" "$(lib "print(c.read_stamp('$T/nope.json'))")" None

# --- pruning ---
r="$(mkrepo prune 'true')"; cd_dir="$r/.git/claude-checks"; mkdir -p "$cd_dir"
echo '{}' > "$cd_dir/old.json"; echo '{}' > "$cd_dir/new.json"; echo keep > "$cd_dir/notes.txt"; echo keep > "$cd_dir/old.txt"
touch -d '20 days ago' "$cd_dir/old.json" "$cd_dir/old.txt"
mkdir "$cd_dir/sub.json"; touch -d '20 days ago' "$cd_dir/sub.json"
run --dir "$r" >/dev/null
[ ! -e "$cd_dir/old.json" ] && ok "old stamp pruned" || bad "old stamp pruned"
[ -e "$cd_dir/new.json" ] && ok "recent stamp kept" || bad "recent stamp kept"
[ -e "$cd_dir/old.txt" ] && [ -e "$cd_dir/notes.txt" ] && ok "non-json files left alone" || bad "non-json files left alone"
[ -d "$cd_dir/sub.json" ] && ok "directories left alone" || bad "directories left alone"

# --- --dir from another cwd, linked worktree ---
r="$(mkrepo wt 'true')"; git -C "$r" worktree add -q -b feat "$T/wt-linked"
out="$(cd "$T/plain" && run --dir "$r")"; eq "--dir works from another cwd" "$(jq -r .status <<<"$out")" passed
out="$(cd "$r" && run)"; eq "default dir is the cwd" "$(jq -r .status <<<"$out")" passed
out="$(cd "$T/plain" && run --dir "$T/wt-linked")"
wh="$(git -C "$T/wt-linked" rev-parse HEAD)"
eq "linked worktree stamp lands in its own git dir" "$(jq -r .stamp <<<"$out")" "$r/.git/worktrees/wt-linked/claude-checks/$wh.json"
[ -f "$(jq -r .stamp <<<"$out")" ] && ok "linked worktree stamp exists" || bad "linked worktree stamp exists"
out="$(cd "$r/.claude" && run --dir "$r/.claude")"; eq "--dir in a subdirectory resolves the repo root" "$(jq -r .stamp <<<"$out")" "$r/.git/claude-checks/$(git -C "$r" rev-parse HEAD).json"

# --- repository untouched ---
r="$(mkrepo untouched $'echo x > scratch-untracked\ntrue')"
snap() { { git -C "$r" rev-parse HEAD; git -C "$r" ls-files -s; git -C "$r" ls-files -z | xargs -0 -I{} sha1sum "$r/{}"; git -C "$r" status --porcelain --untracked-files=no; } | sha1sum; }
b="$(snap)"; run --dir "$r" >/dev/null; eq "HEAD, index and tracked files unchanged" "$(snap)" "$b"

# --- usage ---
out="$(run --bogus)"; rc=$?; eq "unknown argument exits 2" "$rc" 2
out="$(run --dir "$r" --build)"; eq "--build accepted" "$(jq -r .status <<<"$out")" passed

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
