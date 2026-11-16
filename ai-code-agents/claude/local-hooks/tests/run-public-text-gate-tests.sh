#!/usr/bin/env bash
# Payload-driven tests for public-repo-text-gate.sh / _public-text-check.py.
# Throwaway git repos with fake origin remotes, a temp HOME, config and cache,
# and no network: PUBLIC_TEXT_GATE_NO_NETWORK=1 or a stub lookup command.
# Usage: local-hooks/tests/run-public-text-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
gate="bash $hooks/public-repo-text-gate.sh"
base="${TMPDIR:-/tmp}"; mkdir -p "$base"
work="$(mktemp -d "$base/public-text-gate.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME/.claude"
export TMPDIR="$work/tmp"; mkdir -p "$TMPDIR"
export XDG_CACHE_HOME="$work/cache"; mkdir -p "$XDG_CACHE_HOME"
export CLAUDE_PUBLIC_TEXT_GATE_CONF="$work/gate.conf"
export PUBLIC_TEXT_GATE_NO_NETWORK=1
unset CLAUDE_PUBLIC_TEXT_GATE PUBLIC_TEXT_GATE_LOOKUP_CMD
cache="$XDG_CACHE_HOME/claude-hooks/repo-visibility.tsv"

mkrepo() {  # NAME URL
  mkdir -p "$work/$1"; git -C "$work/$1" init -q 2>/dev/null
  git -C "$work/$1" remote add origin "$2"
}
mkrepo pub https://github.com/owner-x/repo-y.git
mkrepo priv git@github.com:owner-x/private-z.git
mkrepo unk https://github.com/owner-x/unknown-q
mkrepo sshurl ssh://git@github.com/owner-x/repo-y.git
mkdir -p "$work/noremote_dir"; git -C "$work/noremote_dir" init -q
plain="$work/plain"; mkdir -p "$plain"

cat >"$work/gate.conf" <<'CONF'
# fake test config
PUBLIC_REPOS="owner-x/repo-y owner-x/pub-*"
PRIVATE_REPOS="owner-x/private-*"
TERMS="fakehost-01 'Fake Project' fakehost"
ALLOW_TERMS="fakehost-docs"
PATTERN=([unclosed
PATTERN=fake-acct-[0-9]{6}
CONF

pass=0; fail=0
# check NAME EXPECT(deny|allow) PAYLOAD
check() {
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | $gate 2>&1)"; rc=$?
  if grep -q '"permissionDecision": *"deny"' <<<"$out"; then got=deny; else got=allow; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); echo "ok   - $name"
  else
    fail=$((fail + 1)); echo "FAIL - $name (expected $expect, got $got, rc=$rc)"; echo "       output: $out"
  fi
}
bp() { jq -n --arg c "$1" --arg d "${2:-$work/pub}" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
ok() {  # NAME CONDITION-RESULT(0 = pass)
  if [ "$2" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1"; fi
}

# --- repo visibility ---
check "configured term in public repo (git commit -m) denied" deny "$(bp 'git commit -m "move to fakehost-01"')"
check "same text in private repo allowed" allow "$(bp 'git commit -m "move to fakehost-01"' "$work/priv")"
check "unknown visibility with network off allowed" allow "$(bp 'git commit -m "move to fakehost-01"' "$work/unk")"
check "no remote allowed" allow "$(bp 'git commit -m "fakehost-01"' "$work/noremote_dir")"
check "not a repo allowed" allow "$(bp 'git commit -m "fakehost-01"' "$plain")"
check "ssh:// remote form (public by config) denied" deny "$(bp 'git commit -m "fakehost-01"' "$work/sshurl")"
mkdir -p "$(dirname "$cache")"
now="$(date +%s)"; old=$((now - 8*86400))
printf 'owner-x/unknown-q\tPUBLIC\t%s\n' "$now" >"$cache"
check "fresh cached PUBLIC entry used" deny "$(bp 'git commit -m "fakehost-01"' "$work/unk")"
printf 'owner-x/unknown-q\tPUBLIC\t%s\n' "$old" >"$cache"
check "8-day-old cache entry ignored" allow "$(bp 'git commit -m "fakehost-01"' "$work/unk")"
rm -f "$cache"
stub_pub="$work/stub-public.sh"; printf '#!/bin/sh\necho PUBLIC\n' >"$stub_pub"
stub_fail="$work/stub-fail.sh"; printf '#!/bin/sh\nexit 1\n' >"$stub_fail"
chmod +x "$stub_pub" "$stub_fail"
out="$(bp 'git commit -m "fakehost-01"' "$work/unk" | PUBLIC_TEXT_GATE_NO_NETWORK=0 PUBLIC_TEXT_GATE_LOOKUP_CMD="$stub_pub" $gate)"
grep -q '"deny"' <<<"$out"; ok "stub lookup PUBLIC denies" $?
grep -q $'^owner-x/unknown-q\tPUBLIC\t' "$cache" 2>/dev/null; ok "stub lookup result cached" $?
check "cached result used on next call (network off)" deny "$(bp 'git commit -m "fakehost-01"' "$work/unk")"
rm -f "$cache"
out="$(bp 'git commit -m "fakehost-01"' "$work/unk" | PUBLIC_TEXT_GATE_NO_NETWORK=0 PUBLIC_TEXT_GATE_LOOKUP_CMD="$stub_fail" $gate)"
[ -z "$out" ]; ok "stub lookup failure allows silently" $?
grep -q $'^owner-x/unknown-q\tUNKNOWN\t' "$cache"; ok "failed lookup cached as UNKNOWN" $?

# --- IPs ---
check "IPv4 denied" deny "$(bp 'git commit -m "server at 10.1.2.3"')"
check "IPv4 at end of sentence denied" deny "$(bp 'git commit -m "server is 10.1.2.3."')"
check "127.0.0.1 allowed" allow "$(bp 'git commit -m "listen on 127.0.0.1"')"
check "0.0.0.0 allowed" allow "$(bp 'git commit -m "bind 0.0.0.0"')"
check "192.0.2.x documentation range allowed" allow "$(bp 'git commit -m "host 192.0.2.44"')"
check "198.51.100.x documentation range allowed" allow "$(bp 'git commit -m "host 198.51.100.7"')"
check "203.0.113.x documentation range allowed" allow "$(bp 'git commit -m "host 203.0.113.9"')"
check "v1.2.3.4 version allowed" allow "$(bp 'git commit -m "bump to v1.2.3.4"')"
check "1.2.3.4.5 dotted number allowed" allow "$(bp 'git commit -m "build 1.2.3.4.5"')"
check "out-of-range octets allowed" allow "$(bp 'git commit -m "ratio 999.1.1.1"')"

# --- hostnames and emails ---
check ".ts.net hostname denied" deny "$(bp 'git commit -m "ssh to box.example-tail.ts.net"')"
check ".local hostname denied" deny "$(bp 'git commit -m "open nas.local"')"
check ".lan hostname denied" deny "$(bp 'git commit -m "open nas.lan"')"
check ".internal hostname denied" deny "$(bp 'git commit -m "call svc.internal"')"
check ".home.arpa hostname denied" deny "$(bp 'git commit -m "call svc.home.arpa"')"
check "email denied" deny "$(bp 'git commit -m "ask someone@mailhost.net"')"
check "noreply email allowed" allow "$(bp 'git commit -m "Co-authored-by: A <noreply@example.org>"')"
check "users.noreply.github.com allowed" allow "$(bp 'git commit -m "by 123+user@users.noreply.github.com"')"

# --- terms, allow-list, patterns ---
check "ALLOW_TERMS lets a term through" allow "$(bp 'git commit -m "see fakehost-docs page"')"
check "ALLOW_TERMS does not hide other terms" deny "$(bp 'git commit -m "fakehost-docs and fakehost-01"')"
check "term is case-insensitive" deny "$(bp 'git commit -m "FakeHost-01 down"')"
check "term inside a longer word allowed" allow "$(bp 'git commit -m "the notfakehostname thing"')"
check "term with space (quoted in config) denied" deny "$(bp 'git commit -m "for fake project launch"')"
check "bad PATTERN skipped, good PATTERN still works" deny "$(bp 'git commit -m "acct fake-acct-123456"')"
check "bad PATTERN does not break clean text" allow "$(bp 'git commit -m "acct fake-acct-12"')"
check "clean text allowed" allow "$(bp 'git commit -m "fix retry loop in parser"')"

# --- gh pr ---
check "gh pr create --title denied (cwd origin)" deny "$(bp 'gh pr create --title "fakehost-01 move" --body ok')"
check "gh pr create --body denied" deny "$(bp 'gh pr create --title ok --body "runs on 10.9.8.7"')"
check "gh pr create --repo public denied from plain cwd" deny "$(bp 'gh pr create --repo owner-x/repo-y --title "fakehost-01" --body x' "$plain")"
check "gh pr create -R public denied" deny "$(bp 'gh pr create -R owner-x/repo-y --title "fakehost-01" --body x' "$plain")"
check "gh pr create --repo= private allowed" allow "$(bp 'gh pr create --repo=owner-x/private-z --title "fakehost-01" --body x' "$work/pub")"
check "gh pr create --repo overrides cwd origin" allow "$(bp 'gh pr create --repo owner-x/private-z --title "fakehost-01" --body x')"
check "gh pr create with no repo anywhere allowed" allow "$(bp 'gh pr create --title "fakehost-01" --body x' "$plain")"
check "gh pr create private cwd allowed" allow "$(bp 'gh pr create --title "fakehost-01" --body x' "$work/priv")"
check "gh pr edit denied" deny "$(bp 'gh pr edit 5 --body "fakehost-01"')"
check "gh pr comment denied" deny "$(bp 'gh pr comment 5 --body "10.4.4.4"')"
check "gh pr review denied" deny "$(bp 'gh pr review 5 --comment --body "nas.local"')"
check "gh pr create clean allowed" allow "$(bp 'gh pr create --title "Add parser" --body "Fixes the loop."')"
check "gh pr view not scanned" allow "$(bp 'gh pr view 5 --repo owner-x/repo-y')"
printf 'summary\nhost fakehost-01 here\n' >"$work/body.md"
check "--body-file contents scanned" deny "$(bp "gh pr create --title t --body-file $work/body.md")"
check "gh pr -F contents scanned" deny "$(bp "gh pr edit 3 -F $work/body.md")"
printf 'summary only\n' >"$work/clean.md"
check "clean body file allowed" allow "$(bp "gh pr create --title t --body-file $work/clean.md")"
check "unreadable body file allowed" allow "$(bp "gh pr create --title t --body-file $work/missing.md")"

# --- commit forms ---
printf 'subject\n\nbox on 10.2.2.2\n' >"$work/msg.txt"
check "git commit -F file contents scanned" deny "$(bp "git commit -F $work/msg.txt")"
check "git commit --file= contents scanned" deny "$(bp "git commit --file=$work/msg.txt")"
check "git commit --message= scanned" deny "$(bp 'git commit --message="fakehost-01"')"
check "git commit -am scanned" deny "$(bp 'git commit -am "fakehost-01"')"
check "git commit with no message allowed" allow "$(bp 'git commit')"
check "git commit --dry-run allowed" allow "$(bp 'git commit --dry-run -m "fakehost-01"')"
check "git -C public dir commit uses that remote" deny "$(bp "git -C $work/pub commit -m fakehost-01" "$work/priv")"
check "git -C private dir commit uses that remote" allow "$(bp "git -C $work/priv commit -m fakehost-01" "$work/pub")"
check "cd public dir && git commit uses that remote" deny "$(bp "cd $work/pub && git commit -m fakehost-01" "$work/priv")"
check "cd private dir && git commit uses that remote" allow "$(bp "cd $work/priv && git commit -m fakehost-01" "$work/pub")"
check "echo \"git commit\" is not a commit" allow "$(bp 'echo "git commit -m fakehost-01"')"

# --- round 2: email forms ---
check "scp-style remote git@host:path allowed" allow "$(bp 'git commit -m "origin is git@github.com:owner-x/repo-y.git"')"
check "user@host:path (other user) allowed" allow "$(bp 'git commit -m "scp deploy@mailhost.net:/srv/x"')"
check "email followed by colon+space still denied" deny "$(bp 'git commit -m "mail me@mailhost.net: thanks"')"
check "example.com address allowed" allow "$(bp 'git commit -m "a@example.com"')"
check "example.org address allowed" allow "$(bp 'git commit -m "a@example.org"')"
check "example.net subdomain address allowed" allow "$(bp 'git commit -m "a@mail.example.net"')"
check ".example TLD address allowed" allow "$(bp 'git commit -m "a@corp.example"')"
check ".test TLD address allowed" allow "$(bp 'git commit -m "a@corp.test"')"
check ".invalid TLD address allowed" allow "$(bp 'git commit -m "a@corp.invalid"')"
check ".localhost TLD address allowed" allow "$(bp 'git commit -m "a@corp.localhost"')"
check "lookalike notexample.com still denied" deny "$(bp 'git commit -m "a@notexample.com"')"
check "Signed-off-by trailer allowed" allow "$(bp $'git commit -m "fix\n\nSigned-off-by: A <a@mailhost.net>"')"
check "Co-authored-by trailer allowed" allow "$(bp $'git commit -m "fix\n\nCo-authored-by: A <a@mailhost.net>"')"
check "Reviewed-by trailer allowed" allow "$(bp $'git commit -m "fix\n\nReviewed-by: A <a@mailhost.net>"')"
check "Acked-by / Tested-by / Reported-by allowed" allow "$(bp $'git commit -m "fix\n\nAcked-by: A <a@mailhost.net>\nTested-by: A <a@mailhost.net>\nReported-by: A <a@mailhost.net>"')"
check "Any Word-by trailer allowed" allow "$(bp $'git commit -m "fix\n\nHelped-by: A <a@mailhost.net>"')"
check "address in body (not trailer) still denied" deny "$(bp $'git commit -m "fix\n\nSigned-off-by: A <a@mailhost.net>\nping b@mailhost.net"')"

# --- IP contexts ---
for ip in 10.0.0.5 172.16.4.4 172.31.1.1 192.168.1.20 100.64.3.3 169.254.9.9; do
  check "private range $ip denied" deny "$(bp "git commit -m \"host $ip\"")"
  check "private range $ip denied after 'version'" deny "$(bp "git commit -m \"version $ip\"")"
  check "private range $ip denied after v" deny "$(bp "git commit -m \"v$ip\"")"
  check "private range $ip denied after @" deny "$(bp "git commit -m \"pkg@$ip\"")"
done
check "172.32.0.1 (outside 172.16/12) read as plain address, denied" deny "$(bp 'git commit -m "host 172.32.0.1"')"
check "release 1.2.3.4 allowed" allow "$(bp 'git commit -m "release 1.2.3.4 done"')"
check "version 1.2.3.4 allowed" allow "$(bp 'git commit -m "version 1.2.3.4"')"
check "ver: 1.2.3.4 allowed" allow "$(bp 'git commit -m "ver: 1.2.3.4"')"
check "build 1.2.3.4 allowed" allow "$(bp 'git commit -m "build 1.2.3.4"')"
check "pkg@1.2.3.4 allowed" allow "$(bp 'git commit -m "pkg@1.2.3.4"')"
check "pkg==1.2.3.4 allowed" allow "$(bp 'git commit -m "pkg==1.2.3.4"')"
check "v-prefixed 1.2.3.4 allowed" allow "$(bp 'git commit -m "tag v1.2.3.4"')"
check "version word on an earlier line does not excuse" deny "$(bp $'git commit -m "version bump\nserver at 8.8.4.4"')"
check "server at 8.8.4.4 denied" deny "$(bp 'git commit -m "server at 8.8.4.4"')"
check "8.8.4.4 bare denied" deny "$(bp 'git commit -m "8.8.4.4"')"

# --- segment discipline ---
printf 'host 10.5.5.5 in log\n' >"$work/log.txt"
check "tail -F log | head; git commit -m ok allowed" allow "$(bp "tail -F $work/log.txt | head -1; git commit -m ok")"
check "other command's -m ignored" allow "$(bp 'echo -m "fakehost-01"; git commit -m ok')"
check "commit file argument after tail -F still scanned" deny "$(bp "tail -F x | head -1; git commit -F $work/log.txt")"
check "git commit && echo with term after segment allowed" allow "$(bp 'git commit -m ok && echo fakehost-01')"
check "gh segment: other command's --body ignored" allow "$(bp 'curl --body fakehost-01 x; gh pr create --title t --body ok')"

# --- gh directory resolution ---
check "cd public && gh pr create from private cwd denied" deny "$(bp "cd $work/pub && gh pr create --title fakehost-01 --body x" "$work/priv")"
check "cd private && gh pr create from public cwd allowed" allow "$(bp "cd $work/priv && gh pr create --title fakehost-01 --body x" "$work/pub")"
check "non-literal cd then gh with a detector hit denied (repository cannot be established)" deny "$(bp 'cd $SOMEWHERE && gh pr create --title fakehost-01 --body x' "$work/pub")"
check "non-literal cd then gh with clean text allowed" allow "$(bp 'cd $SOMEWHERE && gh pr create --title fix --body x' "$work/pub")"
check "cd public && gh pr edit denied" deny "$(bp "cd $work/pub && gh pr edit 3 --body 10.9.9.9" "$plain")"
check "--repo beats cd for gh" allow "$(bp "cd $work/pub && gh pr create --repo owner-x/private-z --title fakehost-01 --body x" "$plain")"

# --- directory not written literally (shared walker: _cmd_dirs.py) ---
reason_has() {  # NAME PAYLOAD REGEX: the deny reason matches
  local r; r="$(printf '%s' "$2" | $gate 2>&1 | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  grep -Eq -- "$3" <<<"$r"; ok "$1" $?
}
PUB="$work/pub"; PRIV="$work/priv"
# resolvable plain assignments are judged exactly like the literal path
check "W=<public>; cd \"\$W\" && commit denied like the literal form" deny "$(bp "W=$PUB; cd \"\$W\" && git commit -m 'move to fakehost-01'" "$PRIV")"
check "W=<private>; cd \"\$W\" && commit allowed like the literal form" allow "$(bp "W=$PRIV; cd \"\$W\" && git commit -m 'move to fakehost-01'" "$PUB")"
check "W=<public>; git -C \"\$W\" commit denied" deny "$(bp "W=$PUB; git -C \"\$W\" commit -m 'move to fakehost-01'" "$PRIV")"
check "W=<private>; git -C \"\$W\" commit allowed" allow "$(bp "W=$PRIV; git -C \"\$W\" commit -m 'move to fakehost-01'" "$PUB")"
check "W=<public>; (cd \"\$W\" && commit) denied" deny "$(bp "W=$PUB; (cd \"\$W\" && git commit -m 'move to fakehost-01')" "$PRIV")"
check "W=<public>; pushd \"\$W\" && commit denied" deny "$(bp "W=$PUB; pushd \"\$W\" >/dev/null && git commit -m 'move to fakehost-01'" "$PRIV")"
check "W=<private>; pushd \"\$W\" && commit allowed" allow "$(bp "W=$PRIV; pushd \"\$W\" >/dev/null && git commit -m 'move to fakehost-01'" "$PUB")"
check "W=<public>; cd \"\$W\" && gh pr create denied" deny "$(bp "W=$PUB; cd \"\$W\" && gh pr create --title fakehost-01 --body x" "$PRIV")"
check "W=<private>; cd \"\$W\" && gh pr create allowed" allow "$(bp "W=$PRIV; cd \"\$W\" && gh pr create --title fakehost-01 --body x" "$PUB")"
check "W=<public>; cd \"\$W\" && git tag -m denied" deny "$(bp "W=$PUB; cd \"\$W\" && git tag -a v9 -m 'on fakehost-01'" "$PRIV")"
# command bodies are judged like the literal forms
check "bash -c with a literal cd into the public repo denied" deny "$(bp "bash -c 'cd $PUB && git commit -m \"move to fakehost-01\"'" "$PRIV")"
check "bash -c with a literal cd into the private repo allowed" allow "$(bp "bash -c 'cd $PRIV && git commit -m \"move to fakehost-01\"'" "$PUB")"
check "bash -c in the public payload directory denied" deny "$(bp "bash -c 'git commit -m \"move to fakehost-01\"'" "$PUB")"
check "sh -c with a resolvable assignment into the public repo denied" deny "$(bp "sh -c 'W=$PUB; cd \"\$W\" && gh pr create --title fakehost-01 --body x'" "$PRIV")"
check "eval of a literal cd into the public repo denied" deny "$(bp "eval \"cd $PUB && git commit -m 'move to fakehost-01'\"" "$PRIV")"
check "nested sh -c / bash -c into the public repo denied" deny "$(bp "sh -c \"bash -c 'cd $PUB && git commit -m fakehost-01'\"" "$PRIV")"
check "env -C <public> commit denied" deny "$(bp "env -C $PUB git commit -m 'fakehost-01'" "$PRIV")"
check "env -C <private> commit allowed" allow "$(bp "env -C $PRIV git commit -m 'fakehost-01'" "$PUB")"
# explicit git directories are judged by their work tree
check "GIT_DIR=<public>/.git commit denied" deny "$(bp "GIT_DIR=$PUB/.git git commit -m 'fakehost-01'" "$plain")"
check "GIT_DIR=<private>/.git commit allowed" allow "$(bp "GIT_DIR=$PRIV/.git git commit -m 'fakehost-01'" "$PUB")"
check "GIT_DIR=\$(pwd)/.git commit with a hit denied (substitution in the prefix)" deny "$(bp "GIT_DIR=\$(pwd)/.git git commit -m 'fakehost-01'" "$plain")"
check "GIT_DIR=backtick commit with a hit denied" deny "$(bp "GIT_DIR=\`pwd\`/.git git commit -m 'fakehost-01'" "$plain")"
check "env GIT_DIR=\$(pwd)/.git commit with a hit denied" deny "$(bp "env GIT_DIR=\$(pwd)/.git git commit -m 'fakehost-01'" "$plain")"
check "bash -c with GIT_DIR=\$(pwd)/.git commit with a hit denied" deny "$(bp "bash -c 'GIT_DIR=\$(pwd)/.git git commit -m \"fakehost-01\"'" "$plain")"
check "GIT_DIR=\$(pwd)/.git commit with a clean text allowed" allow "$(bp "GIT_DIR=\$(pwd)/.git git commit -m 'feat: x'" "$plain")"
# a substitution glued to more text in an argument: the commit stays visible
for form in 'git -C $(pwd)/a commit' 'git -C `pwd`/a commit' 'git -C pre$(pwd)post commit' \
            'git --git-dir=$(pwd)/.git commit' 'git --work-tree=$(pwd)/a commit' 'eval git -C $(pwd)/a commit' \
            'sudo -u root git -C $(pwd)/a commit'; do
  check "substitution glued to an argument, text with a hit denied: $form" deny "$(bp "$form -m 'fakehost-01'" "$plain")"
  check "substitution glued to an argument, clean text allowed: $form" allow "$(bp "$form -m 'feat: x'" "$plain")"
done
# a wrapper argument or a redirection before the subcommand no longer hides the commit (public repository)
for form in 'timeout $(echo 5)s git commit' 'git 2>&1 commit' 'sudo -u $(id -un)x git commit'; do
  check "wrapper argument or redirection before the subcommand, text with a hit denied: $form" deny "$(bp "$form -m 'fakehost-01'")"
  check "wrapper argument or redirection before the subcommand, clean text allowed: $form" allow "$(bp "$form -m 'feat: x'")"
done
check "a term inside a substitution glued to the message is denied in a public repo" deny "$(bp 'git commit -m x$(echo "fakehost-01")y')"
check "a clean substitution glued to the message is allowed in a public repo" allow "$(bp 'git commit -m x$(echo ok)y')"
check "--git-dir/--work-tree on the public repo denied" deny "$(bp "git --git-dir=$PUB/.git --work-tree=$PUB commit -m 'fakehost-01'" "$plain")"
# a directory that cannot be established: a hit is denied, a clean text is silent
for form in 'cd "$W" && git commit -m "TEXT"' \
            'W=$(pwd) && cd "$W" && git commit -m "TEXT"' \
            '(cd "$W" && git commit -m "TEXT")' \
            'pushd "$W" >/dev/null && git commit -m "TEXT"' \
            'git -C "$W" commit -m "TEXT"' \
            'cd "$(pwd)" && git commit -m "TEXT"' \
            'cd - && git commit -m "TEXT"' \
            'GIT_DIR="$W" git commit -m "TEXT"' \
            'git --git-dir="$W" commit -m "TEXT"' \
            'env -C "$W" git commit -m "TEXT"' \
            "bash -c 'cd \"\$W\" && git commit -m \"TEXT\"'" \
            "sh -c 'cd \$W && git commit -m \"TEXT\"'" \
            'cd "$W" && git tag -a v9 -m "TEXT"' \
            'cd "$W" && gh pr create --title "TEXT" --body x' \
            'cd "$W" && gh pr edit 3 --body "TEXT"' \
            'cd "$W" && gh issue create --title t --body "TEXT"'; do
  check "unknown directory, text trips a detector: denied: ${form//TEXT/...}" deny "$(bp "${form//TEXT/move to fakehost-01}" "$PRIV")"
  check "unknown directory, text trips a detector, even from a public payload directory: ${form//TEXT/...}" deny "$(bp "${form//TEXT/box at 10.1.2.3}" "$PUB")"
  check "unknown directory, clean text silent: ${form//TEXT/...}" allow "$(bp "${form//TEXT/fix the parser}" "$PUB")"
done
reason_has "unknown-directory denial says the repository could not be established" "$(bp 'cd "$W" && git commit -m "move to fakehost-01"' "$PRIV")" "could not establish which repository"
reason_has "unknown-directory denial says to write the directory literally" "$(bp 'cd "$W" && git commit -m "move to fakehost-01"' "$PRIV")" "Write the directory literally"
reason_has "unknown-directory denial says the text would be denied if the repository is public" "$(bp 'cd "$W" && git commit -m "move to fakehost-01"' "$PRIV")" "denied if the repository is public"
reason_has "unknown-directory denial names the directory reason" "$(bp 'cd "$W" && git commit -m "move to fakehost-01"' "$PRIV")" "not written literally"
reason_has "unknown-directory denial lists what was found" "$(bp 'cd "$W" && git commit -m "box at 10.1.2.3"' "$PRIV")" "10\\.1\\.2\\.3"
check "unknown directory: built-in email detector denied" deny "$(bp 'cd "$W" && git commit -m "ask someone@mailhost.net"' "$PRIV")"
check "unknown directory: built-in hostname detector denied" deny "$(bp 'cd "$W" && git commit -m "ssh to box.example-tail.ts.net"' "$PRIV")"
check "unknown directory: configured pattern denied" deny "$(bp 'cd "$W" && git commit -m "acct fake-acct-123456"' "$PRIV")"
check "unknown directory: ALLOW_TERMS still lets a term through" allow "$(bp 'cd "$W" && git commit -m "see fakehost-docs page"' "$PRIV")"
check "unknown directory: documentation IP range silent" allow "$(bp 'cd "$W" && git commit -m "host 192.0.2.44"' "$PRIV")"
check "unknown directory: -F absolute message file with a hit denied" deny "$(bp "cd \"\$W\" && git commit -F $work/log.txt" "$PRIV")"
check "unknown directory: heredoc message with a hit denied" deny "$(bp $'cd "$W" && git commit -F - <<EOF\nmove to fakehost-01\nEOF' "$PRIV")"
check "unknown directory: heredoc message clean silent" allow "$(bp $'cd "$W" && git commit -F - <<EOF\nfix parser\nEOF' "$PRIV")"
check "unknown directory: unparseable body holding a commit and a hit denied" deny "$(bp "bash -c 'git commit -m \"fakehost-01 unterminated'" "$PRIV")"
check "unknown directory: unparseable body holding a commit, clean, silent" allow "$(bp "bash -c 'git commit -m \"fix unterminated'" "$PRIV")"
check "no payload cwd, plain commit with a hit stays silent" allow "$(jq -n '{tool_input:{command:"git commit -m \"fakehost-01\""}}')"
many="$(for i in $(seq 1 320); do printf 'cd %s; ' "$PRIV"; done)"
check "line over the analysis budget: a hit denied" deny "$(bp "${many}git commit -m 'move to fakehost-01'" "$PRIV")"
check "line over the analysis budget: clean text silent" allow "$(bp "${many}git commit -m 'fix parser'" "$PRIV")"
# --repo / -R names the repository whatever the directory
check "unknown directory + --repo public: denied" deny "$(bp 'cd "$W" && gh pr create --repo owner-x/repo-y --title fakehost-01 --body x' "$PRIV")"
check "unknown directory + -R public: denied" deny "$(bp 'cd "$W" && gh pr create -R owner-x/repo-y --title fakehost-01 --body x' "$PRIV")"
check "unknown directory + --repo= public: denied" deny "$(bp 'cd "$W" && gh pr create --repo=owner-x/repo-y --title fakehost-01 --body x' "$PRIV")"
check "unknown directory + --repo private: silent" allow "$(bp 'cd "$W" && gh pr create --repo owner-x/private-z --title fakehost-01 --body x' "$PUB")"
check "unknown directory + --repo public, clean text: silent" allow "$(bp 'cd "$W" && gh pr create --repo owner-x/repo-y --title t --body x' "$PRIV")"
check "unknown directory + --repo public (gh pr edit): denied" deny "$(bp 'cd "$W" && gh pr edit 3 -R owner-x/repo-y --body 10.9.9.9' "$PRIV")"
check "unknown directory + --repo naming an unknown-visibility repo: silent" allow "$(bp 'cd "$W" && gh pr create --repo owner-x/unknown-q --title fakehost-01 --body x' "$PRIV")"
reason_has "--repo denial names the repository" "$(bp 'cd "$W" && gh pr create --repo owner-x/repo-y --title fakehost-01 --body x' "$PRIV")" "owner-x/repo-y is a PUBLIC repository"
check "temporary directory + --repo public: denied" deny "$(bp 'cd "$(mktemp -d)" && gh pr create --repo owner-x/repo-y --title fakehost-01 --body x' "$PRIV")"
check "cd \"\$W\" + --repo from a public payload directory, --repo private: silent" allow "$(bp 'cd "$W" && gh pr create --repo owner-x/private-z --title fakehost-01 --body x' "$PUB")"
# a directory made by a bare mktemp -d has no public remote
check "cd \"\$(mktemp -d)\" && commit silent" allow "$(bp 'cd "$(mktemp -d)" && git init -q && git commit -q --allow-empty -m "move to fakehost-01"' "$PUB")"
check "T=\$(mktemp -d); cd \"\$T\" && commit silent" allow "$(bp 'T=$(mktemp -d); cd "$T" && git init -q && git commit -q --allow-empty -m "move to fakehost-01"' "$PUB")"
check "git -C \"\$(mktemp -d)\" commit silent" allow "$(bp 'git -C "$(mktemp -d)" commit --allow-empty -m "move to fakehost-01"' "$PUB")"
check "cd \"\$(mktemp -d)\" && gh pr create silent" allow "$(bp 'cd "$(mktemp -d)" && gh pr create --title fakehost-01 --body x' "$PUB")"
check "mktemp -d with -p is not a temporary directory: denied" deny "$(bp 'cd "$(mktemp -d -p /var/tmp)" && git commit -m "move to fakehost-01"' "$PRIV")"
# text as data, read-only commands and dry runs
check "echo of a git commit with an unknown directory is not a command" allow "$(bp 'cd "$W" && echo "git commit -m fakehost-01"' "$PRIV")"
check "printf of gh pr create is not a command" allow "$(bp "printf '%s' 'gh pr create --title fakehost-01 --body x'" "$PRIV")"
check "a message that mentions git commit, in an unknown directory, is not a command" allow "$(bp 'cd "$W" && grep -n "git commit" fakehost-01.txt' "$PRIV")"
check "git status after an unknown cd allowed" allow "$(bp 'cd "$W" && git status # fakehost-01' "$PRIV")"
check "git log after an unknown cd allowed" allow "$(bp 'cd "$W" && git log --grep=fakehost-01' "$PRIV")"
check "gh pr view after an unknown cd allowed" allow "$(bp 'cd "$W" && gh pr view fakehost-01' "$PRIV")"
check "gh pr list after an unknown cd allowed" allow "$(bp 'cd "$W" && gh pr list --search fakehost-01' "$PRIV")"
check "gh pr checks after an unknown cd allowed" allow "$(bp 'cd "$W" && gh pr checks fakehost-01' "$PRIV")"
check "git commit --dry-run after an unknown cd allowed" allow "$(bp 'cd "$W" && git commit --dry-run -m "move to fakehost-01"' "$PRIV")"

# --- review round: bodies on an over-budget line, -R=, -h as a value, missing shared module ---
for body in "bash -c 'git commit -m \"move to fakehost-01\"'" "sh -c 'git commit -m \"move to fakehost-01\"'" "eval 'git commit -m \"move to fakehost-01\"'" "env -S 'git commit -m \"move to fakehost-01\"'" "bash -c 'gh pr create --title \"fakehost-01\" --body x'"; do
  check "over-budget line: a hit inside a body denied: $body" deny "$(bp "${many}$body" "$PRIV")"
done
check "over-budget line: a clean text inside a body silent" allow "$(bp "${many}bash -c 'git commit -m \"fix parser\"'" "$PRIV")"
check "over-budget line: a body that is not a commit or gh command silent" allow "$(bp "${many}bash -c 'echo fakehost-01'" "$PRIV")"
check "-R=owner/repo public: denied" deny "$(bp 'cd "$W" && gh pr create -R=owner-x/repo-y --title fakehost-01 --body x' "$PRIV")"
check "-R=owner/repo private: silent" allow "$(bp 'cd "$W" && gh pr create -R=owner-x/private-z --title fakehost-01 --body x' "$PUB")"
check "-m -h is a message: a hit after it is judged" deny "$(bp 'git commit -m -h -m "move to fakehost-01"' "$PUB")"
check "git commit -h is a help request: silent" allow "$(bp 'git commit -h -m "move to fakehost-01"' "$PUB")"
# a name later assigned a backtick value is unknown (the stricter resolver), not the stale literal
check "W=<private>; W=\`pwd\`; cd \"\$W\" && commit with a hit: unknown directory, denied" deny "$(bp 'W='"$PRIV"'; W=`pwd`; cd "$W" && git commit -m "move to fakehost-01"' "$PUB")"
check "W=<private>; W=\`pwd\`; cd \"\$W\" && gh pr create with a hit: unknown directory, denied" deny "$(bp 'W='"$PRIV"'; W=`pwd`; cd "$W" && gh pr create --title fakehost-01 --body x' "$PUB")"
# without _cmd_dirs.py the gate falls back to the literal-directory scan
iso4="$(mktemp -d "$work/iso4.XXXXXX")"; cp -r "$hooks" "$iso4/local-hooks"; cp -r "$hooks/../hooks" "$iso4/hooks"; rm -f "$iso4/local-hooks/_cmd_dirs.py"
isocheck() {  # NAME EXPECT PAYLOAD
  local out; out="$(printf '%s' "$3" | bash "$iso4/local-hooks/public-repo-text-gate.sh" 2>/dev/null)"
  { [ "$2" = deny ] && grep -q '"permissionDecision": *"deny"' <<<"$out"; } || { [ "$2" = allow ] && [ -z "$out" ]; }; ok "$1" $?
}
isocheck "without _cmd_dirs.py: a hit in a public literal directory denied" deny "$(bp 'git commit -m "move to fakehost-01"' "$PUB")"
isocheck "without _cmd_dirs.py: --repo public denied" deny "$(bp 'gh pr create --repo owner-x/repo-y --title fakehost-01 --body x' "$PRIV")"
isocheck "without _cmd_dirs.py: a private literal directory silent" allow "$(bp 'git commit -m "move to fakehost-01"' "$PRIV")"
isocheck "without _cmd_dirs.py: an unknown directory is not judged (the old behaviour)" allow "$(bp 'cd "$W" && git commit -m "move to fakehost-01"' "$PRIV")"
errout="$(CMD='git commit -m "move to fakehost-01"' CWD="$PUB" python3 -I "$iso4/local-hooks/_public-text-check.py" 2>&1 >/dev/null)"
[ "$(wc -l <<<"$errout")" -eq 1 ] && grep -q '_cmd_dirs.py could not be loaded' <<<"$errout"; ok "without _cmd_dirs.py: one line on standard error" $?
rm -rf "$iso4"

# --- message on stdin ---
check "git commit -F - heredoc denied" deny "$(bp $'git commit -F - <<EOF\nmove to fakehost-01\nEOF')"
check "git commit -F- heredoc denied" deny "$(bp $'git commit -F- <<\'EOF\'\nbox 10.2.3.4\nEOF')"
check "git commit -F - heredoc clean allowed" allow "$(bp $'git commit -F - <<EOF\nfix parser\nEOF')"
check "cat heredoc | git commit -F - denied" deny "$(bp $'cat <<EOF | git commit -F -\nfakehost-01\nEOF')"
check "gh pr create --body-file - heredoc denied" deny "$(bp $'gh pr create --title t --body-file - <<EOF\nrun on fakehost-01\nEOF')"
check "gh pr create --body-file=- heredoc denied" deny "$(bp $'gh pr create --title t --body-file=- <<EOF\nrun on fakehost-01\nEOF')"
check "gh pr create --body-file - clean heredoc allowed" allow "$(bp $'gh pr create --title t --body-file - <<EOF\nsummary\nEOF')"
check "-F - with no heredoc allowed" allow "$(bp 'echo hi | git commit -F -')"

# --- multi-word terms ---
check "multi-space term denied" deny "$(bp 'git commit -m "for Fake   Project launch"')"
check "term split by newline denied" deny "$(bp $'git commit -m "for Fake\nProject launch"')"
check "term split by tab denied" deny "$(bp $'git commit -m "for Fake\tProject launch"')"

# --- gh issue and git tag ---
check "gh issue create denied" deny "$(bp 'gh issue create --title "fakehost-01" --body x')"
check "gh issue comment denied" deny "$(bp 'gh issue comment 4 --body "10.1.1.1"')"
check "gh issue edit --repo private allowed" allow "$(bp 'gh issue edit 4 --repo owner-x/private-z --body "10.1.1.1"' "$work/pub")"
check "gh issue clean allowed" allow "$(bp 'gh issue create --title "Parser bug" --body x')"
check "git tag -m denied" deny "$(bp 'git tag -a v1 -m "fakehost-01"')"
check "git tag -F file scanned" deny "$(bp "git tag -a v1 -F $work/log.txt")"
check "git tag -m in private repo allowed" allow "$(bp 'git tag -a v1 -m "fakehost-01"' "$work/priv")"
check "git tag listing allowed" allow "$(bp 'git tag -l')"

# --- cache robustness ---
calls="$work/stub-calls"; : >"$calls"
stub_count="$work/stub-count.sh"; printf '#!/bin/sh\necho x >>%s\necho "${STUB_ANSWER:-PUBLIC}"\n' "$calls" >"$stub_count"
stub_unk="$work/stub-unk.sh"; printf '#!/bin/sh\necho x >>%s\nexit 1\n' "$calls" >"$stub_unk"
chmod +x "$stub_count" "$stub_unk"
withstub() {  # STUB PAYLOAD
  printf '%s' "$2" | PUBLIC_TEXT_GATE_NO_NETWORK=0 PUBLIC_TEXT_GATE_LOOKUP_CMD="$1" $gate
}
rm -rf "$XDG_CACHE_HOME/claude-hooks"; mkdir -p "$XDG_CACHE_HOME/claude-hooks"
printf '\xff\xfe\x00garbage\n\xc3\x28\tbad\n' >"$cache"
out="$(withstub "$stub_count" "$(bp 'git commit -m "fakehost-01"' "$work/unk")")"
grep -q '"deny"' <<<"$out"; ok "corrupt cache then PUBLIC stub denies" $?
grep -q $'^owner-x/unknown-q\tPUBLIC\t' "$cache" && ! grep -aq garbage "$cache"; ok "corrupt cache repaired by rewrite" $?
! ls "$XDG_CACHE_HOME/claude-hooks" | grep -q tmp; ok "no temp file left behind" $?
fut=$((now + 86400))
printf 'owner-x/unknown-q\tPUBLIC\t%s\n' "$fut" >"$cache"
check "future-timestamp cache entry ignored" allow "$(bp 'git commit -m "fakehost-01"' "$work/unk")"
rm -f "$cache"; : >"$calls"
withstub "$stub_unk" "$(bp 'git commit -m "fakehost-01"' "$work/unk")" >/dev/null
withstub "$stub_unk" "$(bp 'git commit -m "fakehost-01"' "$work/unk")" >/dev/null
[ "$(wc -l <"$calls")" -eq 1 ]; ok "unknown cached: second run does not call the stub" $?
printf 'owner-x/unknown-q\tUNKNOWN\t%s\n' "$((now - 700))" >"$cache"; : >"$calls"
withstub "$stub_unk" "$(bp 'git commit -m "fakehost-01"' "$work/unk")" >/dev/null
[ "$(wc -l <"$calls")" -eq 1 ]; ok "UNKNOWN entry older than 10 minutes looked up again" $?
printf 'owner-x/unknown-q\tPRIVATE\t%s\n' "$((now - 3600))" >"$cache"; : >"$calls"
withstub "$stub_count" "$(bp 'git commit -m "fakehost-01"' "$work/unk")" >/dev/null
[ "$(wc -l <"$calls")" -eq 0 ]; ok "fresh PRIVATE entry (1h) used without lookup" $?
printf 'owner-x/unknown-q\tPRIVATE\t%s\n' "$((now - 2*86400))" >"$cache"; : >"$calls"
out="$(withstub "$stub_count" "$(bp 'git commit -m "fakehost-01"' "$work/unk")")"
[ "$(wc -l <"$calls")" -eq 1 ] && grep -q '"deny"' <<<"$out"; ok "PRIVATE entry older than 1 day re-looked-up (now public)" $?
printf 'owner-x/unknown-q\tPUBLIC\t%s\n' "$((now - 3*86400))" >"$cache"; : >"$calls"
withstub "$stub_count" "$(bp 'git commit -m "fakehost-01"' "$work/unk")" >/dev/null
[ "$(wc -l <"$calls")" -eq 0 ]; ok "PUBLIC entry (3 days) still trusted" $?
rm -f "$cache"

# --- pathological user pattern ---
cp "$work/gate.conf" "$work/gate.conf.bak2"
printf 'PATTERN=(a+)+$\n' >>"$work/gate.conf"
long="$(printf 'a%.0s' $(seq 1 60))!"
start=$(date +%s)
out="$(printf '%s' "$(bp "git commit -m \"$long 10.8.8.8\"")" | $gate)"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 3 ]; ok "catastrophic PATTERN returns within 3 seconds (${elapsed}s)" $?
grep -q '"deny"' <<<"$out" && grep -q 'IP address' <<<"$out"; ok "built-in detectors still deny after pattern budget" $?
cp "$work/gate.conf.bak2" "$work/gate.conf"

# --- git remote forms: user@ skipped, host still judged ---
check "remote scp github.com:owner/repo.git allowed" allow "$(bp 'git commit -m "origin git@github.com:owner-x/repo-y.git"')"
check "remote ssh:// github.com allowed" allow "$(bp 'git commit -m "origin ssh://git@github.com/owner-x/repo-y.git"')"
check "remote ssh:// with port allowed" allow "$(bp 'git commit -m "origin ssh://git@github.com:22/owner-x/repo-y.git"')"
check "remote git+ssh:// allowed" allow "$(bp 'git commit -m "origin git+ssh://git@github.com/owner-x/repo-y.git"')"
check "remote on ordinary other host allowed" allow "$(bp 'git commit -m "mirror git@gitlab.example-host.io:grp/proj.git"')"
check "remote path ending .git without slash allowed" allow "$(bp 'git commit -m "mirror git@gitlab.example-host.io:proj.git"')"
check "remote on .lan host denied" deny "$(bp 'git commit -m "mirror git@internal-box.lan:grp/repo.git"')"
out="$(bp 'git commit -m "mirror git@internal-box.lan:grp/repo.git"' | $gate)"
grep -q 'internal hostname: internal-box.lan' <<<"$out"; ok "remote .lan host named in denial" $?
! grep -q 'email' <<<"$out"; ok "remote host not also reported as an email" $?
check "ssh:// remote on .local host denied" deny "$(bp 'git commit -m "mirror ssh://git@nas.local/srv/repo.git"')"
check "ssh:// remote on .ts.net host denied" deny "$(bp 'git commit -m "mirror ssh://git@box.example-tail.ts.net:2222/srv/repo.git"')"
check "remote on private IP denied" deny "$(bp 'git commit -m "mirror git@10.0.0.5:grp/repo.git"')"
out="$(bp 'git commit -m "mirror git@10.0.0.5:grp/repo.git"' | $gate)"
grep -q 'IP address: 10.0.0.5' <<<"$out"; ok "remote private IP named in denial" $?
check "ssh:// remote on private IP denied" deny "$(bp 'git commit -m "mirror ssh://git@192.168.1.9/srv/repo.git"')"
check "remote on configured term host denied" deny "$(bp 'git commit -m "mirror deploy@fakehost-01:apps/site.git"')"
check "bob@corp.com:note judged as an email, denied" deny "$(bp 'git commit -m "ping bob@corp.com:note"')"
check "bob@corp.com: see note judged as an email, denied" deny "$(bp 'git commit -m "ping bob@corp.com: see note"')"
out="$(bp 'git commit -m "ping bob@corp.com:note"' | $gate)"
grep -q 'email: bob@corp.com' <<<"$out"; ok "non-remote reported as email" $?

# --- plumbing ---
check "command without git or gh allowed" allow "$(bp 'ls -la')"
start=$(date +%s%N)
printf '%s' "$(bp 'echo hello')" | $gate >/dev/null
[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 400 ]; ok "no-git/gh command exits fast" $?
out="$(bp 'git commit -m "fakehost-01"' | CLAUDE_PUBLIC_TEXT_GATE=off $gate)"
[ -z "$out" ]; ok "off switch allows silently" $?
check "subagent payload also denied" deny "$(bp 'git commit -m "fakehost-01"' | jq '.agent_id="a1"')"
check "non-Bash tool ignored" allow '{"tool_name":"Edit","tool_input":{"file_path":"/x"}}'
check "unbalanced quote: raw text scanned, term denied" deny "$(bp "git commit -m 'unterminated fakehost-01")"
check "unbalanced quote: clean text allowed" allow "$(bp "git commit -m 'unterminated clean")"
check "unbalanced quote: IP denied" deny "$(bp "git commit -m 'unterminated 10.3.3.3")"
check "unbalanced quote, no git/gh word allowed" allow "$(bp "echo 'unterminated 10.3.3.3")"

# built-in detectors still run without a config file
mv "$work/gate.conf" "$work/gate.conf.off"
check "no config: IP still denied when cache says public" allow "$(bp 'git commit -m "10.1.2.3"')"
printf 'owner-x/repo-y\tPUBLIC\t%s\n' "$(date +%s)" >"$cache"
check "no config: built-in IP detector denies via cache" deny "$(bp 'git commit -m "10.1.2.3"')"
check "no config: configured term not enforced" allow "$(bp 'git commit -m "fakehost-01"')"
rm -f "$cache"; mv "$work/gate.conf.off" "$work/gate.conf"

# config is data, never executed
canary="$work/canary"
cp "$work/gate.conf" "$work/gate.conf.bak"
{ cat "$work/gate.conf.bak"; echo "TERMS=\$(touch $canary) \`touch $canary\`"; echo "PATTERN=\$(touch $canary)"; } >"$work/gate.conf"
check "config with \$(...) still enforces" deny "$(bp 'git commit -m "fakehost-01"')"
[ ! -e "$canary" ]; ok "config with \$(...) executed nothing" $?
cp "$work/gate.conf.bak" "$work/gate.conf"

# denial output
nasty=$'say "hi" \\ and\nnewline fakehost-01 10.7.7.7 a@mailhost.net nas.local'
payload="$(jq -n --arg c "git commit -m '$nasty'" --arg d "$work/pub" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')"
out="$(printf '%s' "$payload" | $gate)"
jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' <<<"$out" >/dev/null; ok "denial is valid PreToolUse JSON with quotes and newlines" $?
reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
grep -q 'PUBLIC' <<<"$reason" && grep -q 'owner-x/repo-y' <<<"$reason" && grep -q 'configured term' <<<"$reason" \
  && grep -q 'IP address' <<<"$reason" && grep -q 'internal hostname' <<<"$reason" && grep -q 'email' <<<"$reason" \
  && grep -qi 'remove or generalise' <<<"$reason"; ok "denial names repo, each match kind and the fix" $?
! grep -q 'fake-acct' <<<"$reason"; ok "denial does not echo config contents" $?

# malformed input
check "empty stdin silent" allow ''
check "non-JSON stdin silent" allow 'not json at all'
check "JSON array stdin silent" allow '[1,2]'
check "payload without command allowed" allow '{"tool_name":"Bash","tool_input":{}}'
out="$(printf 'garbage' | $gate 2>&1)"; [ -z "$out" ]; ok "malformed stdin prints nothing" $?

# --- off-file ---
offd="$work/offs"; mkdir -p "$offd"
mkoff() { rm -f "$1"; touch -d "$2" "$1"; }   # FILE "N hours ago" | "N hours"
off="$offd/public-text-gate.off"; export CLAUDE_PUBLIC_TEXT_GATE_OFF_FILE="$off"
bad_cmd='git commit -m "move to fakehost-01"'
reason_of() { printf '%s' "$1" | $gate 2>&1 | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }
rm -f "$off"
check "no off-file: denied as before" deny "$(bp "$bad_cmd")"
mkoff "$off" "1 hour ago"
check "fresh off-file switches the gate off" allow "$(bp "$bad_cmd")"
mkoff "$off" "13 hours ago"
check "13-hour-old off-file ignored" deny "$(bp "$bad_cmd")"
grep -q 'expired' <<<"$(reason_of "$(bp "$bad_cmd")")"; ok "13-hour-old off-file: denial says it expired" $?
mkoff "$off" "2 hours"
check "future-dated off-file ignored" deny "$(bp "$bad_cmd")"
grep -q 'expired' <<<"$(reason_of "$(bp "$bad_cmd")")"; ok "future-dated off-file: denial says it expired" $?
rm -f "$off"
out="$(printf '%s' "$(bp "$bad_cmd")" | CLAUDE_PUBLIC_TEXT_GATE=off $gate 2>&1)"; [ -z "$out" ]; ok "env switch still works with no off-file" $?
! grep -q 'expired' <<<"$(reason_of "$(bp "$bad_cmd")")"; ok "no off-file: denial has no expired note" $?
mkoff "$off" "1 hour ago"
iso="$(mktemp -d "$work/iso.XXXXXX")"; cp -r "$hooks" "$iso/local-hooks"; cp -r "$hooks/../hooks" "$iso/hooks"; rm -f "$iso/local-hooks/_gate-common.sh"
out="$(printf '%s' "$(bp "$bad_cmd")" | bash "$iso/local-hooks/public-repo-text-gate.sh" 2>&1)"
grep -q '"permissionDecision": *"deny"' <<<"$out"; ok "no _gate-common.sh: gate stays ON with fresh off-file" $?
rm -f "$off"
for v in CLAUDE_DELEGATE_GATE_OFF_FILE CLAUDE_WORKTREE_GATE_OFF_FILE CLAUDE_GIT_GUARD_OFF_FILE CLAUDE_SHARED_DB_GATE_OFF_FILE CLAUDE_ACCEPTANCE_GATE_OFF_FILE; do mkoff "$offd/$v" "1 hour ago"; export "$v=$offd/$v"; done
check "other gates' fresh off-files do not switch it off" deny "$(bp "$bad_cmd")"
unset CLAUDE_DELEGATE_GATE_OFF_FILE CLAUDE_WORKTREE_GATE_OFF_FILE CLAUDE_GIT_GUARD_OFF_FILE CLAUDE_SHARED_DB_GATE_OFF_FILE CLAUDE_ACCEPTANCE_GATE_OFF_FILE CLAUDE_PUBLIC_TEXT_GATE_OFF_FILE

echo; echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
