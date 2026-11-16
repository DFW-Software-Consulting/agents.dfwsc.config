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
check "non-literal cd then gh allowed (undeterminable)" allow "$(bp 'cd $SOMEWHERE && gh pr create --title fakehost-01 --body x' "$work/pub")"
check "cd public && gh pr edit denied" deny "$(bp "cd $work/pub && gh pr edit 3 --body 10.9.9.9" "$plain")"
check "--repo beats cd for gh" allow "$(bp "cd $work/pub && gh pr create --repo owner-x/private-z --title fakehost-01 --body x" "$plain")"

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

echo; echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
