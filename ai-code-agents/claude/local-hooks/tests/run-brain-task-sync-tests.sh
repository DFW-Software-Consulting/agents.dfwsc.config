#!/usr/bin/env bash
# Tests for skills/brain-task-sync/collect-evidence.sh. Throwaway repos under
# mktemp -d, a stub gh through BRAIN_TASK_SYNC_GH, no network, no database.
# Usage: local-hooks/tests/run-brain-task-sync-tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../../skills/brain-task-sync/collect-evidence.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       output: $2"; }

# mkrepo DIR REMOTE_URL BRANCH [COMMIT_MESSAGE...]
mkrepo() {
  local d="$1" url="$2" br="$3"; shift 3
  git init -q -b main "$d"
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name t
  git -C "$d" remote add origin "$url"
  git -C "$d" commit -q --allow-empty -m base
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$d" checkout -q -b "$br"
  local m
  for m in "$@"; do git -C "$d" commit -q --allow-empty -m "$m"; done
}
run() { BRAIN_TASK_SYNC_GH="${GHSTUB:-$tmp/no-such-gh}" bash "$script" "$1" 2>&1; echo "rc=$?"; }
has()   { grep -qxF -- "$2" <<<"$1"; }
hasre() { grep -qE -- "$2" <<<"$1"; }

bt="$here/../../skills/brain-task-sync/brain-task.sh"
if [ ! -f "$script" ]; then
  bad "script exists at $script"; echo; echo "$pass passed, $fail failed"; exit 1
fi

# --- remotes ---
mkrepo "$tmp/a" git@github.com:acme/widgets.git fix/732-thing
out="$(run "$tmp/a")"
has "$out" "repo=acme/widgets" && ok "ssh remote with .git" || bad "ssh remote" "$out"
has "$out" "branch=fix/732-thing" && ok "branch reported" || bad "branch" "$out"
has "$out" "default_branch=main" && ok "default branch" || bad "default branch" "$out"
hasre "$out" '^head=[0-9a-f]{7,}$' && ok "head sha" || bad "head sha" "$out"
has "$out" "ref=acme/widgets#732 source=branch strength=strong" && ok "fix/732-thing gives ref" || bad "fix/732-thing" "$out"
has "$out" "rc=0" && ok "exit 0 without gh" || bad "exit 0 without gh" "$out"
has "$out" "gh=missing" && ok "reports gh missing" || bad "gh missing line" "$out"

mkrepo "$tmp/b" https://github.com/acme/widgets feature/issue/41
out="$(run "$tmp/b")"
has "$out" "repo=acme/widgets" && ok "https remote without .git" || bad "https remote" "$out"
has "$out" "ref=acme/widgets#41 source=branch strength=strong" && ok "feature/issue/41" || bad "feature/issue/41" "$out"
mkrepo "$tmp/b2" https://github.com/acme/widgets.git gh-9
out="$(run "$tmp/b2")"
has "$out" "repo=acme/widgets" && ok "https remote with .git" || bad "https .git" "$out"
has "$out" "ref=acme/widgets#9 source=branch strength=strong" && ok "gh-9 branch" || bad "gh-9" "$out"
mkrepo "$tmp/b3" git@github.com:acme/widgets.git 732-thing
out="$(run "$tmp/b3")"
has "$out" "ref=acme/widgets#732 source=branch strength=strong" && ok "732-thing branch" || bad "732-thing" "$out"
mkrepo "$tmp/b4" git@github.com:acme/widgets.git issue-55
out="$(run "$tmp/b4")"
has "$out" "ref=acme/widgets#55 source=branch strength=strong" && ok "issue-55 branch" || bad "issue-55" "$out"

# --- rejected branch shapes ---
for br in docs/context-2026-11-17 release-1.2.3 v2 2026-11-17-notes chore/bump-20260101; do
  mkrepo "$tmp/r" git@github.com:acme/widgets.git "$br"
  out="$(run "$tmp/r")"
  if grep -q '^ref=' <<<"$out"; then bad "branch $br gives no ref" "$out"; else ok "branch $br gives no ref"; fi
  rm -rf "$tmp/r"
done

# --- commit messages ---
mkrepo "$tmp/c" git@github.com:acme/widgets.git topic $'Fix thing (#12)\n\nFixes #13 and color #333' "Depends on #88, see Step #2 and color #333 and #1,#4" "Fixes #89" "closes: other/repo#5" "See https://github.com/acme/widgets/pull/90 and other/repo#9" "relates to #732" "Task 0B6C1C3E-1111-4222-8333-444455556666 done"
out="$(run "$tmp/c")"
has "$out" "ref=acme/widgets#88 source=commit strength=weak" && ok "depends on #88 is weak" || bad "#88 weak" "$out"
has "$out" "ref=other/repo#9 source=commit strength=weak" && ok "cross-repo other/repo#9" || bad "cross repo" "$out"
has "$out" "ref=acme/widgets#90 source=commit strength=weak" && ok "full pull URL in commit is weak" || bad "pull URL" "$out"
has "$out" "ref=acme/widgets#2 source=commit strength=weak" && ok "Step #2 is weak" || bad "#2 weak" "$out"
has "$out" "ref=acme/widgets#89 source=commit strength=strong" && ok "Fixes #89 is strong" || bad "#89 strong" "$out"
has "$out" "ref=other/repo#5 source=commit strength=strong" && ok "closes: other/repo#5 is strong" || bad "other/repo#5 strong" "$out"
has "$out" "ref=acme/widgets#1 source=commit strength=weak" && has "$out" "ref=acme/widgets#4 source=commit strength=weak" && ok "#1,#4 yields both" || bad "#1,#4" "$out"
if grep -q 'widgets#333\|widgets#12 ' <<<"$out"; then bad "color #333 and squash suffix (#12) yield nothing" "$out"; else ok "color #333 and squash suffix (#12) yield nothing"; fi
has "$out" "ref=acme/widgets#13 source=commit strength=strong" && ok "real ref beside colour code and squash suffix is found" || bad "#13 beside colour" "$out"
has "$out" "ref=acme/widgets#732 source=commit strength=weak" && ok "relates to #732 is weak" || bad "relates weak" "$out"
has "$out" "commits=7" && ok "commits line counts scanned commits" || bad "commits line" "$out"
has "$out" "task=0b6c1c3e-1111-4222-8333-444455556666 source=commit strength=strong" && ok "task uuid in commit is strong" || bad "uuid" "$out"
if grep -q 'ref=acme/widgets#9 ' <<<"$out"; then bad "other/repo#9 not attributed to this repo" "$out"; else ok "other/repo#9 not attributed to this repo"; fi

# --- gh stub ---
cat > "$tmp/gh-stub" <<'STUB'
#!/usr/bin/env bash
# one `gh pr view` call: url, state, closing refs, title, body joined by US (0x1f)
printf '%s\n' "$*" >> "${STUB_RECORD:-/dev/null}"
body="${STUB_BODY-Closes #702
SECRETBODY mentions #703
also closes #700}"
printf 'https://github.com/upstream/widgets/pull/77\037%s\037acme/widgets#700\037Add widget (#701) %0200d\001end\037%s\n' "${STUB_STATE:-OPEN}" 0 "$body"
STUB
chmod +x "$tmp/gh-stub"
mkrepo "$tmp/d" git@github.com:acme/widgets.git topic
out="$(GHSTUB="$tmp/gh-stub" run "$tmp/d")"
has "$out" "pr_number=77" && ok "stub pr number" || bad "pr number" "$out"
has "$out" "pr_state=OPEN" && ok "stub pr state" || bad "pr state" "$out"
has "$out" "pr_repo=upstream/widgets" && ok "pr_repo from the PR url" || bad "pr_repo" "$out"
has "$out" "ref=upstream/widgets#77 source=pr-number strength=strong" && ok "pr-number uses the PR url repo" || bad "pr-number" "$out"
has "$out" "ref=acme/widgets#700 source=pr-closes,pr-body strength=strong" && ok "ref found by two sources lists both, strong on OPEN PR" || bad "pr-closes" "$out"
has "$out" "ref=acme/widgets#701 source=pr-body strength=weak" && ok "pr title mention is weak" || bad "pr title ref" "$out"
has "$out" "ref=acme/widgets#702 source=pr-body strength=strong" && ok "Closes #702 in pr body is strong" || bad "pr body strong" "$out"
has "$out" "ref=acme/widgets#703 source=pr-body strength=weak" && ok "plain #703 in pr body is weak" || bad "pr body weak" "$out"
if grep -q 'SECRETBODY\|^pr_body' <<<"$out"; then bad "pr body never printed" "$out"; else ok "pr body never printed"; fi
title="$(grep '^pr_title=' <<<"$out")"
[ "${#title}" -le 129 ] && ! grep -q $'\001' <<<"$title" && ok "pr_title truncated to 120, controls removed" || bad "pr_title hygiene (${#title})" "$title"
has "$out" "rc=0" && ok "exit 0 with gh" || bad "exit 0 with gh" "$out"
rec="$tmp/gh-record"; : > "$rec"
out="$(STUB_RECORD="$rec" GHSTUB="$tmp/gh-stub" run "$tmp/d")"
[ "$(wc -l < "$rec")" -eq 1 ] && ok "gh invoked once" || bad "gh invoked $(wc -l < "$rec") times" "$(cat "$rec")"
grep -q -- '--repo acme/widgets' "$rec" && ok "gh called with --repo origin repo" || bad "--repo missing" "$(cat "$rec")"
# merged PR: nothing derived from it is strong
out="$(STUB_STATE=MERGED GHSTUB="$tmp/gh-stub" run "$tmp/d")"
has "$out" "pr_state=MERGED" && ok "merged state printed" || bad "merged state" "$out"
has "$out" "ref=upstream/widgets#77 source=pr-number strength=weak" && ok "merged PR own number is weak" || bad "merged pr-number" "$out"
if grep '^ref=' <<<"$out" | grep -q 'strength=strong'; then bad "no strong ref from a merged PR" "$out"; else ok "no strong ref from a merged PR"; fi
# task uuid: weak from PR title or body, strong from the branch
out="$(STUB_BODY='Task 0B6C1C3E-1111-4222-8333-444455556666 here' GHSTUB="$tmp/gh-stub" run "$tmp/d")"
has "$out" "task=0b6c1c3e-1111-4222-8333-444455556666 source=pr-body strength=weak" && ok "uuid in PR body is weak" || bad "pr uuid weak" "$out"
mkrepo "$tmp/u" git@github.com:acme/widgets.git feat/0b6c1c3e-1111-4222-8333-444455556666
out="$(run "$tmp/u")"
has "$out" "task=0b6c1c3e-1111-4222-8333-444455556666 source=branch strength=strong" && ok "uuid in branch is strong" || bad "branch uuid" "$out"
# a gh that fails on everything must not break the script
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/gh-fail"; chmod +x "$tmp/gh-fail"
out="$(GHSTUB="$tmp/gh-fail" run "$tmp/d")"
has "$out" "rc=0" && ok "failing gh still exits 0" || bad "failing gh" "$out"
has "$out" "gh=no-pr" && ok "failing gh reported as no-pr" || bad "no-pr line" "$out"

# gh that hangs: reported as a timeout, still exit 0
printf '#!/usr/bin/env bash\nexec sleep 5\n' > "$tmp/gh-hang"; chmod +x "$tmp/gh-hang"
out="$(BRAIN_TASK_SYNC_GH_TIMEOUT=1 GHSTUB="$tmp/gh-hang" run "$tmp/d")"
has "$out" "gh=timeout" && has "$out" "rc=0" && ok "gh timeout reported, exit 0" || bad "gh timeout" "$out"


# --- saved task per branch (brain-task.sh) ---
btr() { bash "$bt" "$@" 2>&1; echo "rc=$?"; }
mkrepo "$tmp/s" git@github.com:acme/widgets.git topic
out="$(btr "$tmp/s" get)"
has "$out" "task=none" && has "$out" "rc=0" && ok "get with nothing saved: task=none, exit 0" || bad "get none" "$out"
out="$(btr "$tmp/s" set 2334)"
has "$out" "task=2334" && has "$out" "rc=0" && ok "set a short id" || bad "set" "$out"
out="$(btr "$tmp/s" get)"; has "$out" "task=2334" && ok "get returns the saved id" || bad "get saved" "$out"
[ "$(git -C "$tmp/s" config --get branch.topic.brain-task)" = "2334" ] && ok "stored in git config for the branch" || bad "config key"
git -C "$tmp/s" status --short | grep -q . && bad "nothing to commit after saving" || ok "saving leaves the working tree clean"
out="$(btr "$tmp/s" set 99)"
has "$out" "refused=different-task-saved old=2334" && has "$out" "rc=0" && ok "replace refused without --replace" || bad "refuse replace" "$out"
out="$(btr "$tmp/s" get)"; has "$out" "task=2334" && ok "refused set keeps the old task" || bad "kept old" "$out"
out="$(btr "$tmp/s" set 99 --replace)"
has "$out" "replaced=2334" && has "$out" "task=99" && ok "--replace replaces" || bad "replace" "$out"
out="$(btr "$tmp/s" set 99)"; has "$out" "task=99" && has "$out" "rc=0" && ok "setting the same id again is fine" || bad "same id" "$out"
for badid in abc 0 012 12345678 "" "1;2" "../x"; do
  out="$(btr "$tmp/s" set "$badid")"
  has "$out" "rc=0" && bad "invalid id [$badid] rejected" "$out" || ok "invalid id [$badid] rejected"
done
out="$(btr "$tmp/s" set 0B6C1C3E-1111-4222-8333-444455556666 --replace)"
has "$out" "task=0b6c1c3e-1111-4222-8333-444455556666" && ok "uuid saved lowercase" || bad "uuid" "$out"
out="$(btr "$tmp/s" bogus)"; has "$out" "rc=0" && bad "bad invocation fails" "$out" || ok "bad invocation fails"
out="$(btr "$tmp/s" clear)"; has "$out" "task=none" && has "$out" "rc=0" && ok "clear" || bad "clear" "$out"
out="$(btr "$tmp/s" get)"; has "$out" "task=none" && ok "get after clear" || bad "get after clear" "$out"
btr "$tmp/s" set 2334 >/dev/null
git -C "$tmp/s" checkout -q main
git -C "$tmp/s" worktree add -q "$tmp/s-wt" topic
out="$(btr "$tmp/s-wt" get)"; has "$out" "task=2334" && ok "a second worktree sees the saved task" || bad "second worktree" "$out"
git -C "$tmp/s" checkout -q topic 2>/dev/null || git -C "$tmp/s" worktree remove --force "$tmp/s-wt"
git -C "$tmp/s" checkout -q --detach
out="$(btr "$tmp/s" get)"; has "$out" "task=none" && has "$out" "detached=true" && has "$out" "rc=0" && ok "detached head: reported, exit 0" || bad "detached get" "$out"
out="$(btr "$tmp/s" set 5)"; has "$out" "detached=true" && has "$out" "saved=false" && ok "detached head: nothing saved" || bad "detached set" "$out"

# --- saved task and Brain-Task trailers as evidence ---
git -C "$tmp/s" checkout -q topic
out="$(run "$tmp/s")"
has "$out" "task=2334 source=saved strength=strong" && ok "saved task emitted as strong evidence" || bad "saved evidence" "$out"
mkrepo "$tmp/tr" git@github.com:acme/widgets.git topic $'Work\n\nBrain-Task: 2334' $'More\n\nbrain-task: #77\nSigned-off-by: x' "Prose about 2334 and Brain-Task: abc and Brain-Task: 5 trailing words" $'Other\n\nBrain-Task: 0B6C1C3E-1111-4222-8333-444455556666'
out="$(run "$tmp/tr")"
has "$out" "task=2334 source=commit strength=strong" && ok "trailer in own commit is strong" || bad "trailer" "$out"
has "$out" "task=77 source=commit strength=strong" && ok "lowercase key and # accepted" || bad "trailer #77" "$out"
has "$out" "task=0b6c1c3e-1111-4222-8333-444455556666 source=commit strength=strong" && ok "uuid trailer" || bad "uuid trailer" "$out"
if grep -q '^task=\(5\|abc\) \|widgets#77\|widgets#2334' <<<"$out"; then bad "non-trailer text and trailer numbers are not refs" "$out"; else ok "non-trailer text and trailer numbers are not refs"; fi
mkrepo "$tmp/tp" git@github.com:acme/widgets.git topic
out="$(STUB_BODY='Brain-Task: 2334' GHSTUB="$tmp/gh-stub" run "$tmp/tp")"
has "$out" "task=2334 source=pr-body strength=strong" && ok "trailer in OPEN PR body is strong" || bad "pr trailer open" "$out"
out="$(STUB_STATE=MERGED STUB_BODY='Brain-Task: 2334' GHSTUB="$tmp/gh-stub" run "$tmp/tp")"
has "$out" "task=2334 source=pr-body strength=weak" && ok "trailer in MERGED PR body is weak" || bad "pr trailer merged" "$out"
out="$(STUB_BODY='Brain-Task: abc
see 2334 here' GHSTUB="$tmp/gh-stub" run "$tmp/tp")"
if grep -q '^task=' <<<"$out"; then bad "Brain-Task: abc and bare 2334 yield nothing" "$out"; else ok "Brain-Task: abc and bare 2334 yield nothing"; fi

# --- saved Brain project (repo-wide) ---
PID=0b6c1c3e-2222-4333-8444-555566667777
mkrepo "$tmp/pj" git@github.com:acme/widgets.git topic
out="$(btr "$tmp/pj" project get)"; has "$out" "project=none" && has "$out" "rc=0" && ok "project get with nothing saved" || bad "project get none" "$out"
out="$(btr "$tmp/pj" project set "${PID^^}")"; has "$out" "project=$PID" && has "$out" "rc=0" && ok "project set (saved lowercase)" || bad "project set" "$out"
out="$(btr "$tmp/pj" project get)"; has "$out" "project=$PID" && ok "project get returns it" || bad "project get" "$out"
[ "$(git -C "$tmp/pj" config --get brain.project-id)" = "$PID" ] && ok "stored as brain.project-id" || bad "project config key"
for badid in abc 123 "" "$PID;x" 0b6c1c3e-2222-4333-8444; do
  out="$(btr "$tmp/pj" project set "$badid")"
  has "$out" "rc=0" && bad "invalid project id [$badid] rejected" "$out" || ok "invalid project id [$badid] rejected"
done
out="$(btr "$tmp/pj" project get)"; has "$out" "project=$PID" && ok "invalid set keeps the saved project" || bad "kept project" "$out"
out="$(run "$tmp/pj")"; has "$out" "project=$PID source=saved" && ok "project evidence line" || bad "project evidence" "$out"
git -C "$tmp/pj" checkout -q main
git -C "$tmp/pj" worktree add -q "$tmp/pj-wt" -b other
out="$(btr "$tmp/pj-wt" project get)"; has "$out" "project=$PID" && ok "second worktree sees the saved project" || bad "project second worktree" "$out"
out="$(btr "$tmp/pj" project clear)"; has "$out" "project=none" && has "$out" "rc=0" && ok "project clear" || bad "project clear" "$out"
out="$(run "$tmp/s")"; if grep -q '^project=' <<<"$out"; then bad "no project line when none saved" "$out"; else ok "no project line when none saved"; fi
out="$(btr "$tmp/pj" project bogus)"; has "$out" "rc=0" && bad "project bad invocation fails" "$out" || ok "project bad invocation fails"

# --- default branch, odd names, project edge cases, copied branches ---
mkrepo "$tmp/db" git@github.com:acme/widgets.git topic
git -C "$tmp/db" checkout -q main
out="$(btr "$tmp/db" set 5)"
has "$out" "task=none reason=default-branch" && has "$out" "rc=0" && ok "set refused on main" || bad "set on main" "$out"
out="$(btr "$tmp/db" get)"; has "$out" "task=none" && ok "nothing saved on main" || bad "main saved" "$out"
git -C "$tmp/db" checkout -q -b master
out="$(btr "$tmp/db" set 5)"; has "$out" "task=none reason=default-branch" && ok "set refused on master" || bad "set on master" "$out"
git -C "$tmp/db" update-ref refs/remotes/origin/develop HEAD
git -C "$tmp/db" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
git -C "$tmp/db" checkout -q -b develop
out="$(btr "$tmp/db" set 5)"; has "$out" "task=none reason=default-branch" && has "$out" "rc=0" && ok "set refused on the origin/HEAD branch" || bad "set on develop" "$out"
git -C "$tmp/db" checkout -q -b work/x
out="$(btr "$tmp/db" set 5)"; has "$out" "task=5" && ok "set still works on a work branch" || bad "work branch" "$out"
git -C "$tmp/db" checkout -q -b "feat/v1.2/x.y"
btr "$tmp/db" set 77 >/dev/null
out="$(btr "$tmp/db" get)"; has "$out" "task=77" && has "$out" "branch=feat/v1.2/x.y" && ok "dots and slashes in the branch name round-trip" || bad "dotted branch" "$out"
git -C "$tmp/db" checkout -q --detach
out="$(btr "$tmp/db" project set 0b6c1c3e-2222-4333-8444-555566667777)"
has "$out" "project=0b6c1c3e-2222-4333-8444-555566667777" && has "$out" "rc=0" && ok "project set works on a detached head" || bad "project detached" "$out"
out="$(btr "$tmp/does-not-exist" project set 0b6c1c3e-2222-4333-8444-555566667777)"
has "$out" "rc=0" && bad "project set in a non-repo exits non-zero" "$out" || { has "$out" "error=not-a-repo" && ok "project set in a non-repo exits non-zero with a message" || bad "non-repo message" "$out"; }
git -C "$tmp/db" checkout -q "feat/v1.2/x.y"
git -C "$tmp/db" branch -c "feat/v1.2/x.y" copied
out="$(btr "$tmp/db" get 2>&1)"
git -C "$tmp/db" checkout -q copied
out="$(btr "$tmp/db" get)"; has "$out" "task=77" && ok "git branch -c copies the saved task (known limit)" || bad "branch -c characterisation" "$out"

# --- trailer with nothing saved: a task= line, never a ref= line ---
mkrepo "$tmp/tn" git@github.com:acme/widgets.git topic $'Work\n\nBrain-Task: 2334'
out="$(run "$tmp/tn")"
has "$out" "task=2334 source=commit strength=strong" && ok "trailer with nothing saved yields a task= line" || bad "trailer task line" "$out"
if grep -q '^ref=' <<<"$out"; then bad "trailer yields no ref= line" "$out"; else ok "trailer yields no ref= line"; fi

# --- negation ---
mkrepo "$tmp/ng" git@github.com:acme/widgets.git topic "This does not fix #5" "Don't close #6" "It doesn't resolve #7" "Fixes #8" "Not ideal. Fixes #9"
out="$(run "$tmp/ng")"
for n in 5 6 7; do has "$out" "ref=acme/widgets#$n source=commit strength=weak" && ok "negated keyword makes #$n weak" || bad "negation #$n" "$out"; done
for n in 8 9; do has "$out" "ref=acme/widgets#$n source=commit strength=strong" && ok "#$n stays strong" || bad "strong #$n" "$out"; done

# --- odd characters ---
mkrepo "$tmp/w" git@github.com:acme/widgets.git topic $'Weird\n\nbody\twith tab\r\nctrl \001 star * qmark ? caf\u00e9 \u2014 Fixes #7'
out="$(run "$tmp/w")"
refs_out="$(grep '^ref=' <<<"$out")"
[ "$refs_out" = "ref=acme/widgets#7 source=commit strength=strong" ] && ok "tab, CR, control, glob and non-ASCII text yield exactly the real ref" || bad "odd characters" "$out"

# --- commit range ---
mkrepo "$tmp/pa" git@github.com:acme/widgets.git feature-a "Fixes #89"
git -C "$tmp/pa" checkout -q -b feature-b
git -C "$tmp/pa" commit -q --allow-empty -m "own work"
out="$(run "$tmp/pa")"
if grep -q '#89' <<<"$out"; then bad "commit from another local branch not scanned" "$out"; else ok "commit from another local branch not scanned"; fi
has "$out" "commits=1" && ok "commits=1 on a branch cut from a local-only branch" || bad "commits=1 child" "$out"
mkrepo "$tmp/m" git@github.com:acme/widgets.git topic "Own work, see #6"
git -C "$tmp/m" checkout -q main
git -C "$tmp/m" commit -q --allow-empty -m "Other PR work for #55"
git -C "$tmp/m" checkout -q topic
git -C "$tmp/m" merge -q --no-ff -m "Merge main into topic, mentions #56" main
out="$(run "$tmp/m")"
has "$out" "ref=acme/widgets#6 source=commit strength=weak" && ok "own commit scanned" || bad "own commit" "$out"
if grep -q '#55\|#56' <<<"$out"; then bad "merged-in main commits and merge commit not scanned" "$out"; else ok "merged-in main commits and merge commit not scanned"; fi
has "$out" "commits=1" && ok "commits=1 after merge of main" || bad "commits=1" "$out"
mkrepo "$tmp/n" git@github.com:acme/widgets.git topic
for i in $(seq 1 51); do git -C "$tmp/n" commit -q --allow-empty -m "step $i of #5"; done
out="$(run "$tmp/n")"
has "$out" "commits=skipped reason=too-many" && ok "more than 50 commits skipped" || bad "too many" "$out"
if grep -q 'source=commit' <<<"$out"; then bad "no commit refs when skipped" "$out"; else ok "no commit refs when skipped"; fi

# --- degraded repos ---
mkrepo "$tmp/e" git@github.com:acme/widgets.git topic
git -C "$tmp/e" checkout -q --detach
out="$(run "$tmp/e")"
has "$out" "rc=0" && ok "detached head exits 0" || bad "detached head" "$out"
has "$out" "branch=" && ok "detached head branch empty" || bad "detached branch" "$out"
git init -q "$tmp/f"
out="$(run "$tmp/f")"
has "$out" "rc=0" && ok "no remote, no commits exits 0" || bad "no remote" "$out"
out="$(run "$tmp/does-not-exist")"
has "$out" "rc=0" && ok "missing dir exits 0" || bad "missing dir" "$out"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
