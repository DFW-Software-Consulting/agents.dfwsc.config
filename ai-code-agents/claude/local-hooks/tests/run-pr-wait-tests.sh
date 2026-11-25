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

# fake gh: FAKE_GH_DIR holds 1.json, 2.json, ... (or N.err for a failing call, whose
# text goes to stderr with exit 1). Call number N uses the highest file <= N.
fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
d="$FAKE_GH_DIR"
printf '%s\n' "$*" >>"$d/calls.log"
n=$(( $(cat "$d/.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/.n"
pick=""
for f in "$d"/*.json "$d"/*.err; do
  [ -e "$f" ] || continue
  b="${f##*/}"; k="${b%%.*}"
  [ "$k" -le "$n" ] && { [ -z "$pick" ] || [ "$k" -ge "$pickk" ]; } && { pick="$f"; pickk="$k"; }
done
[ -n "$pick" ] || { echo "fake gh: no fixture" >&2; exit 1; }
case "$pick" in
  *.err) cat "$pick" >&2; exit 1 ;;
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

changed="$(find "$tmp" -type f -newer "$fakebin/gh" -not -path "$tmp/fx*" -not -name err 2>/dev/null | wc -l)"
[ "$changed" = 0 ] && ok "writes no files of its own" || bad "writes no files of its own" "$changed"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
