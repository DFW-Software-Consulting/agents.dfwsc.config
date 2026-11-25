#!/usr/bin/env bash
# Payload-driven tests for brain-task-reminder.sh. Throwaway repos under mktemp -d,
# a temporary HOME (the conf and off-file are read from it, never from the real
# ~/.claude), no network, no database.
# Usage: local-hooks/tests/run-brain-task-reminder-tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
hook="$hooks/brain-task-reminder.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset CLAUDE_BRAIN_TASK_REMINDER CLAUDE_BRAIN_TASK_REMINDER_OFF_FILE CLAUDE_BRAIN_TASK_REMINDER_CONF
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }

mkrepo() {  # DIR BRANCH [ORIGIN_URL]
  git init -q -b main "$1"
  git -C "$1" config user.email t@example.invalid; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m base
  if [ -n "${3:-}" ]; then git -C "$1" remote add origin "$3"; fi
  git -C "$1" checkout -q -b "$2"
}
# payload CMD CWD [extra JSON object deep-merged into the payload]
payload() {
  local x="${3:-}"; [ -n "$x" ] || x='{}'
  jq -nc --arg c "$1" --arg d "$2" --argjson x "$x" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c},tool_response:{stdout:"",stderr:"",interrupted:false}} * $x'
}
run() { out="$(printf '%s' "$1" | bash "$hook" 2>&1)"; rc=$?; }
silent() { if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "$1"; else bad "$1" "rc=$rc out=$out"; fi; }
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out" 2>/dev/null; }
says() { local c; c="$(ctx)"; if [ "$rc" -eq 0 ] && grep -qF -- "$2" <<<"$c"; then ok "$1"; else bad "$1" "rc=$rc missing [$2] in: $out"; fi; }
lacks() { local c; c="$(ctx)"; if ! grep -qF -- "$2" <<<"$c"; then ok "$1"; else bad "$1" "unexpected [$2] in: $out"; fi; }

r="$tmp/r1";  mkrepo "$r" feat/x git@github.com:acme/widgets.git
git -C "$r" config branch.feat/x.brain-task 4821
r2="$tmp/has space"; mkrepo "$r2" feat/y https://github.com/acme/other.git
git -C "$r2" config branch.feat/y.brain-task 77
rp="$tmp/rp"; mkrepo "$rp" feat/p git@github.com:acme/proj.git
git -C "$rp" config brain.project-id 11111111-2222-3333-4444-555555555555
rn="$tmp/rn"; mkrepo "$rn" feat/n git@github.com:Listed-Org/thing.git
rq="$tmp/rq"; mkrepo "$rq" feat/q git@github.com:other-org/thing.git
nonrepo="$tmp/plain"; mkdir -p "$nonrepo"

# --- reminders ---
run "$(payload 'git push origin feat/x' "$r")"
says "push with saved task names the id" "Brain task 4821"
says "push wording does not claim the push worked" "A push command ran on feat/x"
lacks "no claim of success" "Pushed"
says "push names the push event" "event push"
says "never blocks" "It never blocks"
c="$(ctx)"; [ -n "$c" ] && [ "${#c}" -le 350 ] && ok "reminder is short (${#c} chars)" || bad "reminder length" "${#c}"
jq -e '(keys == ["hookSpecificOutput"]) and (.hookSpecificOutput|keys|sort)==["additionalContext","hookEventName"] and .hookSpecificOutput.hookEventName=="PostToolUse"' >/dev/null <<<"$out" && ok "output shape: PostToolUse additionalContext only" || bad "output shape" "$out"
run "$(payload 'gh pr create --fill' "$r")"
says "gh pr create uses pr wording" "A PR create command ran on feat/x"
says "pr event named" "event pr"
run "$(payload "git -C '$r2' push -u origin feat/y" "$tmp")"
says "git -C with spaces in the path" "Brain task 77"
run "$(payload "cd '$r2' && git push" "$tmp")"
says "cd dir with spaces then push" "Brain task 77"
run "$(payload "bash -c 'cd \"$r\" && git push origin feat/x'" "$tmp")"
says "push inside bash -c" "Brain task 4821"
run "$(payload "git status && git push origin feat/x && echo done" "$r")"
says "push chained with other commands" "Brain task 4821"
run "$(payload 'git push origin feat/p' "$rp")"
says "project saved, no task: find wording" "No Brain task is saved for this branch"
says "find mode named" "find mode"
c="$(ctx)"; [ "${#c}" -le 350 ] && ok "find reminder under 350 chars (${#c})" || bad "find length" "${#c}"
lacks "no task id when none" "on Brain task"

# --- silence ---
run "$(payload 'git push' "$rn")"; silent "nothing saved, no conf: silent"
run "$(payload 'git push --dry-run origin feat/x' "$r")"; silent "git push --dry-run"
run "$(payload 'git push -n origin feat/x' "$r")"; silent "git push -n"
run "$(payload 'git push --help' "$r")"; silent "git push --help"
run "$(payload 'git status' "$r")"; silent "git status"
run "$(payload 'echo "git push" && gh pr list' "$r")"; silent "git push inside an echo string"
run "$(payload 'git push origin feat/x' "$nonrepo")"; silent "non-repo directory"
run "$(payload 'git push origin x' "$tmp/does-not-exist")"; silent "missing directory"
run "$(payload 'git push origin feat/x' "$r" '{"tool_response":{"is_error":true}}')"; silent "failed push (is_error)"
run "$(payload 'git push origin feat/x' "$r" '{"tool_response":{"error":"boom"}}')"; silent "failed push (error string)"
run "$(payload 'git push origin feat/x' "$r" '{"tool_response":{"interrupted":true}}')"; silent "interrupted push"
run "$(payload 'git push origin feat/x' "$r" '{"hook_event_name":"PostToolUseFailure","error":"exit 1"}')"; silent "PostToolUseFailure event"
run "$(payload 'git push origin feat/x' "$r" '{"hook_event_name":"PreToolUse"}')"; silent "PreToolUse event"
run "$(payload 'git push "unclosed' "$r")"; silent "unparseable command"
run "$(payload 'cd "$SOMEWHERE" && git push' "$r")"; silent "directory held in an unknown variable"
run "$(payload 'git push origin feat/x' "")"; silent "no cwd and no literal dir"

# --- owners conf ---
conf="$HOME/.claude/brain-task-reminder.conf"
printf '# owners\nOWNERS=Other, listed-org ,third\n' > "$conf"
run "$(payload 'git push origin feat/n' "$rn")"
says "origin owner listed (case-insensitive): find reminder" "No Brain task is saved for this branch"
run "$(payload 'git push origin feat/q' "$rq")"; silent "origin owner not listed"
printf 'OWNERS=listed-org\n' > "$tmp/alt.conf"; rm -f "$conf"
out="$(printf '%s' "$(payload 'git push' "$rn")" | CLAUDE_BRAIN_TASK_REMINDER_CONF="$tmp/alt.conf" bash "$hook" 2>&1)"; rc=$?
says "conf-path override honoured" "No Brain task is saved"
run "$(payload 'git push' "$rn")"; silent "conf removed: silent again"
printf 'OWNERS=listed-org\n' > "$conf"
run "$(payload 'git push origin feat/x' "$r")"; says "saved task wins over owners list" "Brain task 4821"

# --- off-file ---
off="$HOME/.claude/brain-task-reminder.off"
touch "$off"
run "$(payload 'git push origin feat/x' "$r")"; silent "fresh off-file silences"
python3 -c 'import os, sys, time; t = time.time() - 13 * 3600; os.utime(sys.argv[1], (t, t))' "$off"
run "$(payload 'git push origin feat/x' "$r")"; says "stale off-file (older than 12h) is ignored" "Brain task 4821"
rm -f "$off"
out="$(printf '%s' "$(payload 'git push origin feat/x' "$r")" | CLAUDE_BRAIN_TASK_REMINDER=off bash "$hook" 2>&1)"; rc=$?; silent "CLAUDE_BRAIN_TASK_REMINDER=off"

# --- fix round: bytecode, wording, flags, branch scope ---
rm -rf "$hooks/__pycache__"
out="$(printf '%s' "$(payload 'git push origin feat/x' "$r")" | env -u PYTHONDONTWRITEBYTECODE bash "$hook" 2>&1)"; rc=$?
says "reached python and reminded" "Brain task 4821"
[ -z "$(find "$hooks" -name __pycache__ -o -name '*.pyc' | head -1)" ] && ok "no bytecode written next to the hook" || bad "bytecode written in $hooks"

# gh pr create flags
run "$(payload 'gh pr create --dry-run' "$r")"; silent "gh pr create --dry-run"
run "$(payload 'gh pr create --help' "$r")"; silent "gh pr create --help"
run "$(payload 'gh pr create -h' "$r")"; silent "gh pr create -h"
run "$(payload 'gh pr create --repo other/repo --fill' "$r")"; silent "gh pr create --repo other repo"
run "$(payload 'gh pr create -R other/repo' "$r")"; silent "gh pr create -R other repo"
run "$(payload 'gh pr create --repo Acme/Widgets --title t' "$r")"; says "gh pr create --repo origin's repo reminds" "feat/x"
run "$(payload 'gh pr create --head other --fill' "$r")"; silent "gh pr create --head other"
run "$(payload 'gh pr create --head feat/x --title "a b" --body x' "$r")"; says "gh pr create --head current reminds" "feat/x"
run "$(payload 'gh pr create --title t --draft --base main' "$r")"; says "gh pr create with no head reminds" "feat/x"
run "$(payload 'gh pr create --weird-flag' "$r")"; silent "gh pr create unknown flag"

# push scope: only the checked-out branch
for a in 'origin main' 'origin HEAD:other' 'origin feat/x:other' 'origin other:feat/x' '--tags' 'origin --tags' '--delete origin feat/x' '-d origin feat/x' '--mirror' '--all' 'origin :feat/x' '--no-such-flag' '--prune origin'; do
  run "$(payload "git push $a" "$r")"; silent "push $a: silent"
done
for a in '' 'origin' '-u origin feat/x' 'origin HEAD' 'origin feat/x' 'origin HEAD:feat/x' 'origin refs/heads/feat/x' 'origin +feat/x' '--force-with-lease' '--force-with-lease=feat/x origin feat/x' '-f' '--no-verify -q origin'; do
  run "$(payload "git push $a" "$r")"; says "push $a: reminds" "feat/x"
done

# branch name printing
wb="$(printf 'a|b$c"d'"'"'e\xe2\x80\xaef')"
bidi="$(printf '\xe2\x80\xae')"
rw="$tmp/rw"; mkrepo "$rw" "$wb" git@github.com:acme/w.git
git -C "$rw" config "branch.$wb.brain-task" 99
run "$(payload 'git push' "$rw")"
says "odd branch name: still reminds" "Brain task 99"
says "odd branch name: says this branch" "ran on this branch"
lacks "odd branch name is not printed" '|'
lacks "odd branch name: no bidi" "$bidi"
jq -e . >/dev/null <<<"$out" && ok "odd branch name: valid JSON" || bad "odd branch json" "$out"

# fail to silence
out="$(printf '%s' "$(payload 'git push' "$r")" | env -u HOME bash "$hook" 2>&1)"; rc=$?; silent "HOME unset"
iso="$tmp/iso"; mkdir -p "$iso/local-hooks" "$iso/skills/brain-task-sync"
cp "$hooks/brain-task-reminder.sh" "$hooks/_brain-task-reminder-check.py" "$hooks/_cmd_dirs.py" "$hooks/_git-cmd-scan.py" "$hooks/_bash-write-check.py" "$hooks/_gate-common.sh" "$iso/local-hooks/"
cp "$hooks/../skills/brain-task-sync/brain-task.sh" "$iso/skills/brain-task-sync/"
out="$(printf '%s' "$(payload 'git push' "$r")" | bash "$iso/local-hooks/brain-task-reminder.sh" 2>&1)"; rc=$?; says "isolated copy works (control)" "Brain task 4821"
rm "$iso/local-hooks/_gate-common.sh"
out="$(printf '%s' "$(payload 'git push' "$r")" | bash "$iso/local-hooks/brain-task-reminder.sh" 2>&1)"; rc=$?; silent "_gate-common.sh missing"
cp "$hooks/_gate-common.sh" "$iso/local-hooks/"; rm "$iso/skills/brain-task-sync/brain-task.sh"
out="$(printf '%s' "$(payload 'git push' "$r")" | bash "$iso/local-hooks/brain-task-reminder.sh" 2>&1)"; rc=$?; silent "helper missing"

# hot path: python starts only for a real candidate
fake="$tmp/fakebin"; mkdir -p "$fake"; real_py="$(command -v python3)"
printf '#!/bin/sh\ntouch "%s/py-ran"\nexec "%s" "$@"\n' "$tmp" "$real_py" > "$fake/python3"; chmod +x "$fake/python3"
for c in 'ls -la' 'prod --flag create' 'git status' 'gh pr list' 'echo push'; do
  rm -f "$tmp/py-ran"; out="$(printf '%s' "$(payload "$c" "$r")" | PATH="$fake:$PATH" bash "$hook" 2>&1)"; rc=$?
  [ ! -e "$tmp/py-ran" ] && [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "no python for: $c" || bad "python started for: $c"
done
rm -f "$tmp/py-ran"; out="$(printf '%s' "$(payload 'git push' "$r")" | PATH="$fake:$PATH" bash "$hook" 2>&1)"; [ -e "$tmp/py-ran" ] && ok "python starts for git push (control)" || bad "control: python did not start"

# agent_type
run "$(payload 'git push' "$r" '{"agent_type":"git-workflow"}')"; silent "agent_type git-workflow"
run "$(payload 'git push' "$r" '{"agent_type":"executor"}')"; says "other agent_type reminds" "Brain task 4821"

# saved values
ru="$tmp/ru"; mkrepo "$ru" feat/u git@github.com:acme/u.git
git -C "$ru" config branch.feat/u.brain-task ABCDEF12-3456-7890-ABCD-EF1234567890
run "$(payload 'git push' "$ru")"; says "uppercase uuid printed lowercase" "Brain task abcdef12-3456-7890-abcd-ef1234567890"
git -C "$ru" config branch.feat/u.brain-task 'x; rm -rf /"'
run "$(payload 'git push' "$ru")"; silent "garbage saved task, no project: silent"
git -C "$ru" config brain.project-id 11111111-2222-3333-4444-555555555555
run "$(payload 'git push' "$ru")"; says "garbage saved task counts as no task" "No Brain task is saved"
lacks "garbage value never printed" "rm -rf"
git -C "$ru" config branch.feat/u.brain-task 0123
run "$(payload 'git push' "$ru")"; says "leading-zero task counts as no task" "No Brain task is saved"

# more command shapes
rd="$tmp/rd"; mkrepo "$rd" feat/d git@github.com:acme/d.git; git -C "$rd" config branch.feat/d.brain-task 5
git -C "$rd" checkout -q --detach; run "$(payload 'git push' "$rd")"; silent "detached HEAD"
run "$(payload 'command git push origin feat/x' "$r")"; says "command git push" "Brain task 4821"
run "$(payload 'env X=1 git push origin feat/x' "$r")"; says "env X=1 git push" "Brain task 4821"
run "$(payload 'git stash push -m x' "$r")"; silent "git stash push"
run "$(payload $'cat <<EOF\ngit push origin feat/x\nEOF' "$r")"; silent "push inside a heredoc"
run "$(payload 'git commit -m "then git push origin feat/x"' "$r")"; silent "push inside a commit message"
run "$(payload 'git push 2>&1 | tail -3' "$r")"; says "push piped to tail reminds" "A push command ran on feat/x"
c="$(ctx)"; grep -q 'If it went through' <<<"$c" && ok "pipeline wording is conditional" || bad "conditional wording" "$c"
# A relative cd resolves against the payload cwd, which is assumed to be the directory the command started in.
mkdir -p "$r/sub"; mkdir -p "$r/plainsub"
run "$(payload 'cd sub && git push' "$r")"; says "relative cd from the payload cwd" "Brain task 4821"
rs="$tmp/parent"; mkdir -p "$rs/notrepo"
run "$(payload 'cd notrepo && git push' "$rs")"; silent "relative cd into a non-repository"

# off-file shapes (the shared helper: a directory or dangling link is no file; a link to a fresh regular file counts)
mkdir "$off"; run "$(payload 'git push' "$r")"; says "off-file that is a directory does not silence" "Brain task 4821"; rmdir "$off"
ln -s "$tmp/nowhere" "$off"; run "$(payload 'git push' "$r")"; says "dangling off-file link does not silence" "Brain task 4821"; rm -f "$off"
touch "$tmp/realoff"; ln -s "$tmp/realoff" "$off"; run "$(payload 'git push' "$r")"; silent "link to a fresh regular file silences (shared helper rule)"; rm -f "$off"

# --- review round: effective push configuration, branch switches, web PRs, GIT_DIR, hosts, candidates ---
# A push with no refspec goes where the push configuration says, not necessarily to the checked-out branch.
rc1="$tmp/rc1"; mkrepo "$rc1" feat/x git@github.com:acme/widgets.git; git -C "$rc1" config branch.feat/x.brain-task 4821
git -C "$rc1" config remote.origin.push refs/heads/release:refs/heads/release
run "$(payload 'git push origin' "$rc1")"; silent "remote.origin.push names another branch: git push origin silent"
run "$(payload 'git push' "$rc1")"; silent "remote.origin.push names another branch: bare git push silent"
run "$(payload 'git push -u origin' "$rc1")"; silent "remote.origin.push names another branch: git push -u origin silent"
git -C "$rc1" config --replace-all remote.origin.push 'refs/heads/feat/x:refs/heads/other'
run "$(payload 'git push origin' "$rc1")"; silent "remote.origin.push maps to another name: silent"
git -C "$rc1" config --replace-all remote.origin.push HEAD
run "$(payload 'git push origin' "$rc1")"; says "remote.origin.push = HEAD still reminds" "Brain task 4821"
git -C "$rc1" config --replace-all remote.origin.push 'refs/heads/*:refs/heads/*'
run "$(payload 'git push origin' "$rc1")"; says "remote.origin.push = same-name pattern still reminds" "Brain task 4821"
git -C "$rc1" config --replace-all remote.origin.push '+refs/heads/feat/x:refs/heads/feat/x'
run "$(payload 'git push' "$rc1")"; says "remote.origin.push = own branch (forced) still reminds" "Brain task 4821"
git -C "$rc1" config --add remote.origin.push 'refs/heads/release:refs/heads/release'
run "$(payload 'git push' "$rc1")"; silent "several push refspecs, one is another branch: silent"
git -C "$rc1" config --unset-all remote.origin.push
git -C "$rc1" config remote.up.url git@github.com:acme/up.git
git -C "$rc1" config remote.up.push 'refs/heads/release:refs/heads/release'
run "$(payload 'git push up' "$rc1")"; silent "push config of the named remote (up) applies"
run "$(payload 'git push origin' "$rc1")"; says "push config of another remote does not apply" "Brain task 4821"
git -C "$rc1" config branch.feat/x.pushRemote up
run "$(payload 'git push' "$rc1")"; silent "branch pushRemote selects the remote whose config applies"
git -C "$rc1" config --unset branch.feat/x.pushRemote
git -C "$rc1" config push.default upstream; git -C "$rc1" config branch.feat/x.merge refs/heads/trunk
run "$(payload 'git push origin' "$rc1")"; silent "push.default=upstream with a differently named upstream: silent"
git -C "$rc1" config branch.feat/x.merge refs/heads/feat/x
run "$(payload 'git push origin' "$rc1")"; says "push.default=upstream, upstream has the same name: reminds" "Brain task 4821"
git -C "$rc1" config push.default matching
run "$(payload 'git push origin' "$rc1")"; silent "push.default=matching: silent"
git -C "$rc1" config push.default nothing
run "$(payload 'git push origin' "$rc1")"; silent "push.default=nothing: silent"
git -C "$rc1" config push.default current
run "$(payload 'git push origin' "$rc1")"; says "push.default=current reminds" "Brain task 4821"
git -C "$rc1" config push.default simple
run "$(payload 'git push origin' "$rc1")"; says "push.default=simple reminds" "Brain task 4821"
git -C "$rc1" config remote.origin.push refs/heads/release:refs/heads/release
run "$(payload 'git push origin feat/x' "$rc1")"; says "an explicit refspec overrides remote.origin.push" "Brain task 4821"
git -C "$rc1" config --unset-all remote.origin.push

# The hook runs after the whole command: a later branch switch means the checkout is not the pushed branch.
run "$(payload 'git push && git switch main' "$r")"; silent "push then git switch: silent"
run "$(payload 'git push origin; git checkout -b other' "$r")"; silent "push then git checkout: silent"
run "$(payload 'git push && git -C '"'$r'"' rebase main' "$r")"; silent "push then git rebase: silent"
run "$(payload 'gh pr create --fill && git switch main' "$r")"; silent "gh pr create then git switch: silent"
run "$(payload 'git switch feat/x && git push' "$r")"; says "git switch then push: reminds" "Brain task 4821"
run "$(payload 'git status && git push' "$r")"; says "push after unrelated git commands reminds" "Brain task 4821"

# gh pr create --web opens a browser form: no PR exists yet
run "$(payload 'gh pr create --web' "$r")"; silent "gh pr create --web silent"
run "$(payload 'gh pr create -w --title t' "$r")"; silent "gh pr create -w silent"
run "$(payload 'gh pr create --web=true' "$r")"; silent "gh pr create --web=true silent"

# a Git directory or work-tree override makes gh read another repository
run "$(payload 'env GIT_DIR=/elsewhere/.git gh pr create --fill' "$r")"; silent "GIT_DIR override on gh pr create: silent"
run "$(payload 'GIT_WORK_TREE=/elsewhere gh pr create --fill' "$r")"; silent "GIT_WORK_TREE override on gh pr create: silent"

# --repo with a host: github.com/acme/widgets names origin; another host does not
run "$(payload 'gh pr create --repo github.com/acme/widgets --fill' "$r")"; says "--repo github.com/acme/widgets reminds" "feat/x"
run "$(payload 'gh pr create --repo https://github.com/acme/widgets --fill' "$r")"; says "--repo https://github.com/acme/widgets reminds" "feat/x"
run "$(payload 'gh pr create --repo ghe.example.com/acme/widgets --fill' "$r")"; silent "--repo on another host: silent"
run "$(payload 'gh pr create --repo github.com/other/widgets --fill' "$r")"; silent "--repo github.com/other/widgets: silent"

# several pushes in one command: the first eligible one counts, not just the first one
run "$(payload 'git push origin release && git push origin feat/x' "$r")"; says "ineligible push first, eligible push second: reminds" "Brain task 4821"
run "$(payload 'git push origin release && git push origin other' "$r")"; silent "two ineligible pushes: silent"
run "$(payload 'git push origin feat/x && git push origin release' "$r")"; says "eligible push first: reminds" "Brain task 4821"

# off-file on a host whose stat has no -c (BSD/macOS): only `stat -f %m` works
bsd="$tmp/bsdbin"; mkdir -p "$bsd"; real_stat="$(command -v stat)"
printf '#!/bin/sh\ncase "$*" in *" -c "*|"-c "*|*"-L -c"*) exit 1 ;; esac\nif [ "$1" = -L ]; then shift; fi\nif [ "$1" = -f ] && [ "$2" = %%m ]; then exec "%s" -c %%Y "$3"; fi\nexit 1\n' "$real_stat" > "$bsd/stat"; chmod +x "$bsd/stat"
touch "$off"
out="$(printf '%s' "$(payload 'git push origin feat/x' "$r")" | PATH="$bsd:$PATH" bash "$hook" 2>&1)"; rc=$?; silent "fresh off-file silences where stat has only the BSD form"
python3 -c 'import os, sys, time; t = time.time() - 13 * 3600; os.utime(sys.argv[1], (t, t))' "$off"
out="$(printf '%s' "$(payload 'git push origin feat/x' "$r")" | PATH="$bsd:$PATH" bash "$hook" 2>&1)"; rc=$?; says "stale off-file still ignored where stat has only the BSD form" "Brain task 4821"
rm -f "$off"

# --- bad input ---
run ''; silent "empty input"
run 'not json'; silent "malformed JSON"
run '[1,2]'; silent "JSON array"
run '{"tool_input":{"command":5}}'; silent "non-string command"
run '{"tool_input":{}}'; silent "no command"

# --- writes nothing ---
touch "$tmp/marker"; sleep 1
run "$(payload 'git push origin feat/x' "$r")"
[ -z "$(find "$hooks" -name __pycache__ -o -name '*.pyc' | head -1)" ] || bad "bytecode in hook dir at end"
changed="$(find "$tmp" -type f -newer "$tmp/marker" -not -path '*/.git/*' 2>/dev/null | wc -l)"
[ "$changed" = 0 ] && ok "writes no files" || bad "writes no files" "$changed files changed"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
