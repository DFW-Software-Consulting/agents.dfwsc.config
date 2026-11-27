#!/usr/bin/env bash
# CLI tests for bin/pr-wait. A fake `gh` is placed first on PATH and replays canned
# responses from a fixture directory, one per call (the last one repeats). No network,
# no real gh, no real config. Time is controlled only through the real flags and
# PR_WAIT_GRACE_SECS.
# Usage: local-hooks/tests/run-pr-wait-tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "$here/../.." && pwd)/bin/pr-wait"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset PR_WAIT_GRACE_SECS GH_TOKEN GITHUB_TOKEN
# The suite polls with a zero interval to stay fast; the script only allows that with this
# override (the zero-value usage cases below run with it unset).
export PR_WAIT_ALLOW_ZERO_INTERVAL=1

# fake gh: FAKE_GH_DIR holds 1.json, 2.json, ... (or N.err for a failing call, whose
# text goes to stderr with exit 1). Call number N uses the highest file <= N.
fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
d="$FAKE_GH_DIR"
printf '%s\n' "$*" >>"$d/calls.log"
# gh api calls read fixed fixtures and do not advance the pr-view call counter
if [ "${1:-}" = api ]; then
  case "$2" in
    */comments*) cat "$d/comments.json" 2>/dev/null || echo '[]' ;;
    */check-suites*)
      ns=$(( $(cat "$d/.ns" 2>/dev/null || echo 0) + 1 )); echo "$ns" >"$d/.ns"
      if [ "$ns" -gt "$(cat "$d/suites.skip" 2>/dev/null || echo 0)" ] && [ -e "$d/suites.json" ]; then cat "$d/suites.json"
      else echo "fake gh: no suites" >&2; exit 1; fi ;;
    *) echo "fake gh: unknown api $2" >&2; exit 1 ;;
  esac
  exit 0
fi
n=$(( $(cat "$d/.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/.n"
pick=""
for f in "$d"/[0-9]*.json "$d"/[0-9]*.err "$d"/[0-9]*.hang; do
  [ -e "$f" ] || continue
  b="${f##*/}"; k="${b%%.*}"
  [ "$k" -le "$n" ] && { [ -z "$pick" ] || [ "$k" -ge "$pickk" ]; } && { pick="$f"; pickk="$k"; }
done
[ -n "$pick" ] || { echo "fake gh: no fixture" >&2; exit 1; }
case "$pick" in
  *.err) cat "$pick" >&2; exit 1 ;;
  *.hang) sleep 30; exit 1 ;;
  *) cat "$pick" ;;
esac
GH
chmod +x "$fakebin/gh"
export PATH="$fakebin:$PATH"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
fx=""
newfx() { fx="$tmp/fx$RANDOM$RANDOM"; mkdir -p "$fx"; export FAKE_GH_DIR="$fx"; }
# put N STATE SHA ROLLUP_JSON
put() { printf '{"state":"%s","headRefOid":"%s","statusCheckRollup":%s}\n' "$2" "$3" "$4" >"$fx/$1.json"; }
cr() { printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":"%s"}' "$1" "$2" "$3"; }
run() { out="$("$@" 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"; last="$(tail -n1 <<<"$out")"; }
expect() {  # NAME RC LASTLINE-REGEX
  if [ "$rc" -eq "$2" ] && grep -Eq -- "$3" <<<"$last"; then ok "$1"
  else bad "$1" "rc=$rc (want $2) last=[$last] (want /$3/) err=[$err]"; fi
}
sc() { printf '{"__typename":"StatusContext","context":"%s","state":"%s"}' "$1" "$2"; }
R=octo/demo

newfx; put 1 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS),$(cr lint COMPLETED NEUTRAL),$(cr docs COMPLETED SKIPPED)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "green (success, neutral, skipped)" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+\$"
grep -q '^pr view 7 -R octo/demo --json state,headRefOid,statusCheckRollup$' "$fx/calls.log" \
  && [ "$(grep -vc '^pr view ' "$fx/calls.log")" = 0 ] && ok "only calls gh pr view" || bad "only calls gh pr view" "$(cat "$fx/calls.log")"

newfx; put 1 OPEN $SHA1 "[$(cr build IN_PROGRESS ''),$(cr lint COMPLETED SUCCESS)]"
put 2 OPEN $SHA1 "[$(cr build COMPLETED FAILURE),$(cr lint COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "failed:<check>" 1 "^PR-WAIT octo/demo#7 failed:build sha=$SHA1 mins=[0-9]+\$"
[ "$(wc -l <<<"$out")" -ge 2 ] && ok "one line per state change (pending line before result)" || bad "state change lines" "$out"

newfx; put 1 OPEN $SHA1 "[$(cr build IN_PROGRESS '')]"
run bash "$script" $R 7 --interval 0s --timeout 1s
expect "timeout" 2 "^PR-WAIT octo/demo#7 timeout sha=$SHA1 mins=[0-9]+\$"
[ "$(wc -l <<<"$out")" -le 4 ] && ok "unchanged state is not reprinted" || bad "unchanged state is not reprinted" "$(wc -l <<<"$out") lines"

newfx; put 1 OPEN $SHA2 "[$(cr build IN_PROGRESS '')]"
run bash "$script" $R 7 --sha $SHA1 --interval 0s --timeout 5s
expect "head-changed with --sha" 3 "^PR-WAIT octo/demo#7 head-changed sha=$SHA2 mins=[0-9]+\$"

newfx; put 1 OPEN $SHA1 "[$(cr build IN_PROGRESS '')]"; put 2 OPEN $SHA2 "[$(cr build IN_PROGRESS '')]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "head-changed without --sha" 3 "^PR-WAIT octo/demo#7 head-changed sha=$SHA2 mins=[0-9]+\$"

newfx; put 1 CLOSED $SHA1 "[]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "closed" 4 "^PR-WAIT octo/demo#7 closed sha=$SHA1 mins=[0-9]+\$"

newfx; put 1 MERGED $SHA1 "[$(cr build COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "merged" 4 "^PR-WAIT octo/demo#7 closed sha=$SHA1 mins=[0-9]+\$"

newfx; put 1 OPEN $SHA1 "[]"; put 2 OPEN $SHA1 "[]"; put 3 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "empty rollup for two polls then green (race)" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+\$"

newfx; put 1 OPEN $SHA1 "[]"
PR_WAIT_GRACE_SECS=1 run bash "$script" $R 7 --interval 0s --timeout 20s
expect "no-checks after the grace window" 5 "^PR-WAIT octo/demo#7 no-checks sha=$SHA1 mins=[0-9]+\$"

newfx
for i in 1 2 3; do echo "HTTP 401: Bad credentials; token ghp_abcdefghijklmnopqrstuvwxyz0123456789 and github_pat_11ABCDEFG0abcdefghijklmnop_qrstuvwxyz0123456789 rejected (gh auth login)" >"$fx/$i.err"; done
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "three gh failures give exit 10 and error:<class>" 10 "^PR-WAIT octo/demo#7 error:[a-z]+ sha=[^ ]+ mins=[0-9]+\$"
if grep -q 'ghp_\|github_pat_\|abcdefghijklmnop' <<<"$out$err"; then bad "no token text in output" "$out $err"; else ok "no token text in output"; fi
[ "$(cat "$fx/.n")" = 3 ] && ok "stops after three consecutive gh errors" || bad "stops after three gh errors" "calls=$(cat "$fx/.n")"

newfx; echo "HTTP 502 Bad Gateway" >"$fx/1.err"
put 2 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "one gh failure then success still reaches green" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+\$"

newfx; echo "HTTP 502" >"$fx/1.err"; echo "HTTP 502" >"$fx/2.err"; put 3 OPEN $SHA1 "[$(cr b IN_PROGRESS '')]"
echo "HTTP 502" >"$fx/4.err"; echo "HTTP 502" >"$fx/5.err"; put 6 OPEN $SHA1 "[$(cr b COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "gh errors are consecutive, not cumulative" 0 "^PR-WAIT octo/demo#7 green"

newfx; put 1 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
for args in "" "octo/demo" "octo/demo abc" "nodash 7" "octo/demo 7 --bogus" "octo/demo 7 --timeout" "octo/demo 7 --timeout xyz" "octo/demo 7 --interval -1" "octo/demo 7 --sha" "octo/demo 7 extra"; do
  # shellcheck disable=SC2086
  run bash "$script" $args
  if [ "$rc" -eq 10 ] && grep -qi 'usage' <<<"$out$err" && grep -q '^PR-WAIT ' <<<"$last"; then ok "bad arguments exit 10 with usage: [$args]"
  else bad "bad arguments exit 10 with usage: [$args]" "rc=$rc out=[$out] err=[$err]"; fi
done
[ ! -e "$fx/calls.log" ] && ok "usage errors never call gh" || bad "usage errors never call gh"

# legacy commit statuses (state instead of conclusion)
newfx; put 1 OPEN $SHA1 "[$(sc ci/legacy FAILURE),$(cr build COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "status FAILURE gives failed" 1 "^PR-WAIT octo/demo#7 failed:ci/legacy sha=$SHA1 mins=[0-9]+\$"
newfx; put 1 OPEN $SHA1 "[$(sc ci/legacy ERROR)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "status ERROR gives failed" 1 "^PR-WAIT octo/demo#7 failed:ci/legacy "
newfx; put 1 OPEN $SHA1 "[$(sc ci/legacy PENDING)]"; put 2 OPEN $SHA1 "[$(sc ci/legacy SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "status PENDING then SUCCESS gives green" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 "
newfx; put 1 OPEN $SHA1 "[$(sc ci/legacy EXPECTED)]"
run bash "$script" $R 7 --interval 0s --timeout 1s
expect "status EXPECTED stays pending (timeout)" 2 "^PR-WAIT octo/demo#7 timeout "
newfx; put 1 OPEN $SHA1 "[$(sc ci/legacy WEIRD)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "unrecognised status state is never green" 1 "^PR-WAIT octo/demo#7 failed:ci/legacy "

# mixed pending and failed, other failing conclusions
newfx; put 1 OPEN $SHA1 "[$(cr slow IN_PROGRESS ''),$(cr build COMPLETED FAILURE)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "failed plus pending reports failed on the first poll" 1 "^PR-WAIT octo/demo#7 failed:build "
[ "$(cat "$fx/.n")" = 1 ] && ok "failed plus pending needs one poll only" || bad "failed plus pending needs one poll only" "calls=$(cat "$fx/.n")"
newfx; put 1 OPEN $SHA1 "[$(sc ci/legacy PENDING),$(cr build COMPLETED CANCELLED)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "CANCELLED beside a pending status gives failed" 1 "^PR-WAIT octo/demo#7 failed:build "
newfx; put 1 OPEN $SHA1 "[$(cr build COMPLETED TIMED_OUT)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "TIMED_OUT gives failed" 1 "^PR-WAIT octo/demo#7 failed:build "
newfx; put 1 OPEN $SHA1 "[$(cr build COMPLETED '')]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "completed with an empty conclusion is never green" 1 "^PR-WAIT octo/demo#7 failed:build "

# names must not decide the verdict
newfx; put 1 OPEN $SHA1 "[$(cr '' COMPLETED FAILURE)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "one check, FAILURE, empty name exits 1" 1 "^PR-WAIT octo/demo#7 failed:unknown sha=$SHA1 "
newfx; put 1 OPEN $SHA1 "[$(sc '' FAILURE)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "status FAILURE with an empty context exits 1" 1 "^PR-WAIT octo/demo#7 failed:unknown "
newfx; put 1 OPEN $SHA1 "[$(cr '\u001b\u0007' COMPLETED FAILURE)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "control-only name still fails, shown as unknown" 1 "^PR-WAIT octo/demo#7 failed:unknown sha="
newfx; put 1 OPEN $SHA1 "[$(cr 'a\u001b[31mred\u0007\u009bb' COMPLETED FAILURE)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
if [ "$rc" -eq 1 ] && ! grep -q '[[:cntrl:]]' <<<"$out" && grep -q 'failed:a\[31mredb' <<<"$last"; then ok "control and escape bytes are stripped from check names"
else bad "control and escape bytes are stripped from check names" "rc=$rc out=$(printf %q "$out")"; fi

# head commit id missing: fail closed as a gh error
newfx; printf '{"state":"OPEN","headRefOid":"","statusCheckRollup":[%s]}\n' "$(cr build COMPLETED SUCCESS)" >"$fx/1.json"
run bash "$script" $R 7 --sha $SHA1 --interval 0s --timeout 5s
expect "empty head id is a gh error, not green" 10 "^PR-WAIT octo/demo#7 error:gh "
newfx; printf '{"state":"OPEN","statusCheckRollup":[%s]}\n' "$(cr build COMPLETED SUCCESS)" >"$fx/1.json"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "missing head id without --sha is a gh error too" 10 "^PR-WAIT octo/demo#7 error:gh "

# zero interval and zero timeout are usage errors (zero interval only with the override unset)
newfx; put 1 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
for args in "--interval 0" "--interval 0s" "--timeout 0" "--timeout 0m"; do
  # shellcheck disable=SC2086
  PR_WAIT_ALLOW_ZERO_INTERVAL="" run bash "$script" $R 7 $args
  if [ "$rc" -eq 10 ] && grep -q '^PR-WAIT octo/demo#7 error:usage ' <<<"$last"; then ok "zero value rejected: [$args]"
  else bad "zero value rejected: [$args]" "rc=$rc out=[$out] err=[$err]"; fi
done
[ ! -e "$fx/calls.log" ] && ok "zero-value usage errors never call gh" || bad "zero-value usage errors never call gh"


# ---- finding 2: early green. A check that registers late must not be missed.
newfx; put 1 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
put 2 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS),$(cr lint IN_PROGRESS '')]"
put 3 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS),$(cr lint COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "late-registering check is not missed (green only after settling)" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 "
[ "$(cat "$fx/.n")" -ge 4 ] && ok "green needs two consecutive no-pending polls" || bad "green needs two consecutive no-pending polls" "calls=$(cat "$fx/.n")"
newfx; put 1 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "stable all-success rollup is still green" 0 "^PR-WAIT octo/demo#7 green "
[ "$(cat "$fx/.n")" = 2 ] && ok "stable green takes exactly two polls" || bad "stable green takes exactly two polls" "calls=$(cat "$fx/.n")"

# ---- finding 3: every gh call is bounded, so --timeout holds
newfx; : >"$fx/1.hang"
SECONDS=0; run bash "$script" $R 7 --interval 0s --timeout 2s; took=$SECONDS
expect "hung gh: overall timeout result" 2 "^PR-WAIT octo/demo#7 timeout "
[ "$took" -le 8 ] && ok "hung gh returns on time (${took}s for --timeout 2s)" || bad "hung gh returns on time" "took ${took}s"
newfx; : >"$fx/1.hang"
SECONDS=0; PR_WAIT_NO_TIMEOUT_CMD=1 run bash "$script" $R 7 --interval 0s --timeout 2s; took=$SECONDS
expect "hung gh without coreutils timeout: overall timeout result" 2 "^PR-WAIT octo/demo#7 timeout "
[ "$took" -le 8 ] && ok "hung gh returns on time via the fallback (${took}s)" || bad "hung gh fallback returns on time" "took ${took}s"
newfx; : >"$fx/1.err"
PR_WAIT_OUTAGE_SECS=0 run bash "$script" $R 7 --interval 0s --timeout 5s
grep -q 'gh error (1): [^ ]' <<<"$out" && ok "an empty gh error is described, not blank" || bad "an empty gh error is described, not blank" "$out"

# ---- finding 4: outages are ridden out with backoff, measured in time
newfx; for i in 1 2 3 4; do echo "HTTP 502 Bad Gateway" >"$fx/$i.err"; done
put 5 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
PR_WAIT_OUTAGE_SECS=30 PR_WAIT_BACKOFF_MAX_SECS=1 run bash "$script" $R 7 --interval 1s --timeout 40s
expect "four transient gh errors are ridden out" 0 "^PR-WAIT octo/demo#7 green "
newfx; echo "HTTP 502 Bad Gateway" >"$fx/1.err"
PR_WAIT_OUTAGE_SECS=2 PR_WAIT_BACKOFF_MAX_SECS=1 run bash "$script" $R 7 --interval 1s --timeout 40s
expect "an outage past the tolerance ends with error:gh" 10 "^PR-WAIT octo/demo#7 error:gh "
grep -q 'gh unavailable for [0-9]*s (tolerance 2s).*HTTP 502' <<<"$out" && ok "the final message names the outage length, tolerance and last error" || bad "outage final message" "$out"

# ---- finding 1: opt-in review-bot wait
# rvl LOGIN SHA STATE: a review; rv SHA: CodeRabbit COMMENTED review
rvl() { printf '{"author":{"login":"%s"},"commit":{"oid":"%s"},"state":"%s"}' "$1" "$2" "$3"; }
rv() { rvl coderabbitai "$1" COMMENTED; }
# putr N SHA ROLLUP REVIEWS
putr() { printf '{"state":"OPEN","headRefOid":"%s","statusCheckRollup":%s,"reviews":%s}\n' "$2" "$3" "$4" >"$fx/$1.json"; }
MARK='<!-- This is an auto-generated comment: skip review by coderabbit.ai -->'
# cm UPDATED_AT BODY_SHA [LOGIN]: the bot's summary comment (skip marker plus a commit id)
cm() { printf '[{"user":{"login":"%s"},"body":"%s\\n<!-- change_assessment_commit:\\"%s\\" -->","updated_at":"%s"}]\n' "${3:-coderabbitai[bot]}" "$MARK" "$2" "$1" >"$fx/comments.json"; }
suites() { printf '{"check_suites":[{"created_at":"%s"},{"created_at":"%s"}]}\n' "${1:-2026-11-20T10:00:00Z}" "${1:-2026-11-20T10:00:09Z}" >"$fx/suites.json"; }
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
crw() { printf '{"__typename":"CheckRun","name":"%s","workflowName":"CI","status":"%s","conclusion":"%s"}' "$1" "$2" "$3"; }
GREEN="[$(cr build COMPLETED SUCCESS)]"
RA="--review coderabbit"
G100=100

newfx; putr 1 $SHA1 "$GREEN" "[$(rv $SHA2)]"; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
expect "review of an older head never counts (keeps waiting)" 2 "^PR-WAIT octo/demo#7 timeout sha=$SHA1 mins=[0-9]+ review=pending\$"
newfx; putr 1 $SHA1 "$GREEN" "[$(rv $SHA2)]"; suites
PR_WAIT_REVIEW_GRACE_SECS=1 run bash "$script" $R 7 $RA --interval 0s --timeout 20s
expect "bot reviewed an older head, silent on this one: absent-for-head, stop waiting" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+ review=absent-for-head\$"
newfx; putr 1 $SHA1 "$GREEN" "[$(rv $SHA2),$(rv $SHA1)]"
run bash "$script" $R 7 $RA --interval 0s --timeout 5s
expect "review of the current head is done" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+ review=reviewed\$"
for st in COMMENTED APPROVED CHANGES_REQUESTED; do
  newfx; putr 1 $SHA1 "$GREEN" "[$(rvl coderabbitai $SHA1 $st)]"
  run bash "$script" $R 7 $RA --interval 0s --timeout 5s
  expect "a $st review of the current head counts" 0 "review=reviewed\$"
done
for st in DISMISSED PENDING; do
  newfx; putr 1 $SHA1 "$GREEN" "[$(rvl coderabbitai $SHA1 $st)]"; suites "$NOW"
  PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
  expect "a $st review of the current head does not count" 2 "^PR-WAIT octo/demo#7 timeout .* review=pending\$"
done
newfx; putr 1 $SHA1 "$GREEN" "[$(rvl notcoderabbitai $SHA1 COMMENTED),$(rvl coderabbitai-fan $SHA1 APPROVED),$(rvl xcoderabbitai[bot] $SHA1 COMMENTED)]"
cm 2026-11-20T10:05:00Z $SHA1 coderabbitai-fan; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
expect "another bot or a human with coderabbit in the login is not CodeRabbit" 2 "^PR-WAIT octo/demo#7 timeout .* review=pending\$"

newfx; putr 1 $SHA1 "$GREEN" "[]"; cm 2026-11-20T10:05:00Z $SHA1; suites
run bash "$script" $R 7 $RA --interval 0s --timeout 5s
expect "skip comment naming the current head is done" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+ review=skipped\$"
newfx; putr 1 $SHA1 "$GREEN" "[]"; cm 2026-11-21T10:05:00Z $SHA2; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
expect "summary comment about an older head, edited after the push, does not count" 2 "^PR-WAIT octo/demo#7 timeout .* review=pending\$"
newfx; putr 1 $SHA1 "$GREEN" "[]"
printf '[{"user":{"login":"coderabbitai[bot]"},"body":"%s","updated_at":"2026-11-21T10:05:00Z"}]\n' "$MARK" >"$fx/comments.json"; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
expect "a skip marker with no commit id is not accepted alone" 2 "^PR-WAIT octo/demo#7 timeout .* review=pending\$"

newfx; putr 1 $SHA1 "$GREEN" "[]"
PR_WAIT_REVIEW_GRACE_SECS=1 run bash "$script" $R 7 $RA --interval 0s --timeout 20s
expect "bot never seen: absent, reported, and the wait stops" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+ review=absent\$"
grep -q 'review bot absent' <<<"$out" && ok "absent bot has its own status line" || bad "absent bot has its own status line" "$out"
newfx; putr 1 $SHA1 "$GREEN" "[]"; : >"$fx/suites.skip"; echo 1 >"$fx/suites.skip"; suites
printf '[{"user":{"login":"coderabbitai[bot]"},"body":"x","updated_at":"2026-11-21T10:05:00Z"}]\n' >"$fx/comments.json"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 5s
expect "a failed check-suites lookup is retried; the fallback push time is not cached" 0 "review=absent-for-head\$"
[ "$(grep -c 'check-suites' "$fx/calls.log")" -ge 2 ] && ok "check-suites is looked up again after a failure" || bad "check-suites retried" "$(cat "$fx/calls.log")"

# check rows: exact CodeRabbit row only
newfx; putr 1 $SHA1 "[$(cr build COMPLETED SUCCESS),$(cr CodeRabbit COMPLETED SKIPPED)]" "[]"
run bash "$script" $R 7 $RA --interval 0s --timeout 5s
expect "a settled (even skipped) CodeRabbit check row is done" 0 "review=check\$"
newfx; putr 1 $SHA1 "[$(cr build COMPLETED SUCCESS),$(cr CodeRabbit IN_PROGRESS '')]" "[]"; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=1 run bash "$script" $R 7 $RA --interval 0s --timeout 3s
expect "a pending CodeRabbit check row keeps waiting and counts as present" 2 "^PR-WAIT octo/demo#7 timeout .* review=pending\$"
newfx; putr 1 $SHA1 "[$(cr build COMPLETED SUCCESS),$(cr coderabbit-lint COMPLETED SUCCESS),$(crw CodeRabbit COMPLETED SUCCESS)]" "[]"; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
expect "coderabbit-lint and a workflow job named CodeRabbit are not the bot's row" 2 "^PR-WAIT octo/demo#7 timeout .* review=pending\$"

# comments are fetched only when checks are settled, with since, and capped
newfx; putr 1 $SHA1 "[$(cr build IN_PROGRESS '')]" "[]"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
[ ! -e "$fx/calls.log" ] || ! grep -q 'issues/7/comments' "$fx/calls.log" && ok "no comment fetch while checks are pending" || bad "no comment fetch while checks are pending" "$(grep -c comments "$fx/calls.log") fetches"
newfx; putr 1 $SHA1 "$GREEN" "[]"; cm 2026-11-21T10:05:00Z $SHA2; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
grep 'issues/7/comments' "$fx/calls.log" | sed -n 2p | grep -q 'since=2026-11-21T10:05:00Z' && ok "later comment fetches ask only for comments updated since the last one" || bad "comment fetch uses since" "$(grep comments "$fx/calls.log" | head -3)"
newfx; putr 1 $SHA1 "$GREEN" "[]"; suites "$NOW"
jq -n '[range(100) | {user:{login:"someone"},body:"hi",updated_at:"2026-11-21T10:05:00Z"}]' >"$fx/comments.json"
PR_WAIT_COMMENT_PAGES=2 PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 2s
grep -q 'capped at 2 pages' <<<"$out" && [ "$(grep -c 'page=3' "$fx/calls.log")" = 0 ] && ok "comment pages are capped and the output says so" || bad "comment pages capped" "$out"

newfx; putr 1 $SHA1 "$GREEN" "[]"; cm 2026-11-20T10:05:00Z $SHA1
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "flag off: unchanged result line, no review field" 0 "^PR-WAIT octo/demo#7 green sha=$SHA1 mins=[0-9]+\$"
[ "$(grep -vc '^pr view 7 -R octo/demo --json state,headRefOid,statusCheckRollup$' "$fx/calls.log")" = 0 ] && ok "flag off: only the original gh pr view call" || bad "flag off: only the original call" "$(cat "$fx/calls.log")"
newfx; putr 1 $SHA1 "$GREEN" "[]"; cm 2026-11-20T10:05:00Z $SHA1; suites
run bash "$script" $R 7 $RA --interval 0s --timeout 5s
if awk '{print $1" "$2}' "$fx/calls.log" | sed -E 's/\?.*//' | sort -u | grep -Evq '^(pr view|api repos/octo/demo/(issues/7/comments|commits/.*/check-suites))$'; then bad "flag on: only read-only gh calls" "$(sort -u "$fx/calls.log")"
elif grep -Eq -- ' (-X|--method|-f|-F|--field|--input)( |$)' "$fx/calls.log"; then bad "flag on: gh api calls are plain GETs" "$(cat "$fx/calls.log")"
else ok "flag on: only gh pr view and plain gh api GETs"; fi
newfx; putr 1 $SHA1 "$GREEN" "[]"
run bash "$script" $R 7 --review nobody --interval 0s --timeout 5s
expect "--review with an unknown bot is a usage error" 10 "error:usage"
newfx; putr 1 $SHA1 "$GREEN" "[]"; echo 'not json' >"$fx/comments.json"; suites "$NOW"
PR_WAIT_REVIEW_GRACE_SECS=100 run bash "$script" $R 7 $RA --interval 0s --timeout 5s
expect "malformed comments JSON counts toward the permanent-error stop" 10 "^PR-WAIT octo/demo#7 error:gh "

# ---- gh error classes
newfx; for i in 1 2 3; do echo "gh: API rate limit exceeded for user ID 1. If you reach out to GitHub Support (HTTP 403) Retry-After: 1" >"$fx/$i.err"; done
put 4 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
SECONDS=0; PR_WAIT_OUTAGE_SECS=30 run bash "$script" $R 7 --interval 0s --timeout 40s; took=$SECONDS
expect "a 403 rate limit is transient and ridden out" 0 "^PR-WAIT octo/demo#7 green "
[ "$took" -ge 3 ] && ok "Retry-After is respected (${took}s for three 1 s waits)" || bad "Retry-After is respected" "took ${took}s"
newfx; for i in 1 2 3; do echo "You have exceeded a secondary rate limit. Please wait a few minutes before you try again (HTTP 403)" >"$fx/$i.err"; done
put 4 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
PR_WAIT_OUTAGE_SECS=30 run bash "$script" $R 7 --interval 0s --timeout 40s
expect "a secondary rate limit is transient too" 0 "^PR-WAIT octo/demo#7 green "
newfx; for i in 1 2 3; do echo "HTTP 502 Bad Gateway (request 4017, login-service, token bucket)" >"$fx/$i.err"; done
put 4 OPEN $SHA1 "[$(cr build COMPLETED SUCCESS)]"
PR_WAIT_OUTAGE_SECS=30 run bash "$script" $R 7 --interval 0s --timeout 40s
expect "stray digits and words (401, login, token) do not make an error auth" 0 "^PR-WAIT octo/demo#7 green "
newfx; echo "gh: Resource not accessible by integration (HTTP 403)" >"$fx/1.err"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "a plain 403 (no rate limit) still stops after three as auth" 10 "^PR-WAIT octo/demo#7 error:auth "
newfx; echo "To get started with GitHub CLI, please run:  gh auth login" >"$fx/1.err"
run bash "$script" $R 7 --interval 0s --timeout 5s
expect "gh auth login text is auth" 10 "^PR-WAIT octo/demo#7 error:auth "

changed="$(find "$tmp" -type f -newer "$fakebin/gh" -not -path "$tmp/fx*" -not -name err 2>/dev/null | wc -l)"
[ "$changed" = 0 ] && ok "writes no files of its own" || bad "writes no files of its own" "$changed"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
