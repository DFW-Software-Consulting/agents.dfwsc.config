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
[ ! -s "$cache" ]; ok "failed lookup not cached" $?

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
check "email denied" deny "$(bp 'git commit -m "ask someone@example.org"')"
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

# --- plumbing ---
check "command without git or gh allowed" allow "$(bp 'ls -la')"
start=$(date +%s%N)
printf '%s' "$(bp 'echo hello')" | $gate >/dev/null
[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 400 ]; ok "no-git/gh command exits fast" $?
out="$(bp 'git commit -m "fakehost-01"' | CLAUDE_PUBLIC_TEXT_GATE=off $gate)"
[ -z "$out" ]; ok "off switch allows silently" $?
check "subagent payload also denied" deny "$(bp 'git commit -m "fakehost-01"' | jq '.agent_id="a1"')"
check "non-Bash tool ignored" allow '{"tool_name":"Edit","tool_input":{"file_path":"/x"}}'
check "unparseable command allowed" allow "$(bp "git commit -m 'unterminated fakehost-01")"

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
nasty=$'say "hi" \\ and\nnewline fakehost-01 10.7.7.7 a@example.org nas.local'
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
