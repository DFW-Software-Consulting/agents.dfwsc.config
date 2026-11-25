#!/usr/bin/env bash
# CLI tests for bin/pr-land (notify-only: it never merges). The seam is the command line:
# arguments, exit code, stdout lines, and the state files and notices.log it leaves.
# A fake `gh` is first on PATH, replays canned JSON per PR number and records every argv
# it is called with; a fake notifier records what it is given. HOME and the XDG
# directories are throwaway. "Now" is PR_LAND_NOW. No network, no real gh, no real config.
# Usage: local-hooks/tests/run-pr-land-tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "$here/../.." && pwd)/bin/pr-land"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$HOME"
unset GH_TOKEN GITHUB_TOKEN
sd="$XDG_STATE_HOME/pr-land"
fx="$tmp/fx"; export FAKE_GH_DIR="$fx" GH_ALL_LOG="$tmp/gh-all.log"
export NOTIF_LOG="$tmp/notif.log" NOTIF_FAIL="$tmp/notif.fail"
export PR_LAND_NOW=2026-11-24T12:00:00Z

fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
d="$FAKE_GH_DIR"
printf '%s\n' "$*" >>"$d/calls.log"
printf '%s\n' "$*" >>"$GH_ALL_LOG"
if [ -n "${FAKE_GH_RELEASE:-}" ]; then  # handshake: say we are in, then block until released (20 s hard bound)
  : >"$d/entered"
  for _ in $(seq 1 400); do [ -e "$FAKE_GH_RELEASE" ] && break; sleep 0.05; done
fi
pr="$3"
if [ -e "$d/fail-$pr.txt" ]; then cat "$d/fail-$pr.txt" >&2; exit 1; fi
[ -e "$d/resp-$pr.json" ] || { echo "fake gh: no fixture for $pr" >&2; exit 1; }
cat "$d/resp-$pr.json"
GH
chmod +x "$fakebin/gh"
cat >"$tmp/notify.sh" <<'N'
#!/usr/bin/env bash
[ -e "$NOTIF_FAIL" ] && exit 1
printf '%s\n' "$1" >>"$NOTIF_LOG"
printf '%s\n' "$#" >>"$NOTIF_LOG.argc"
N
chmod +x "$tmp/notify.sh"
export PATH="$fakebin:$PATH"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

R=octo/demo
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
fresh() { rm -rf "$sd" "$XDG_CONFIG_HOME" "$fx" "$NOTIF_LOG" "$NOTIF_LOG.argc" "$NOTIF_FAIL"; mkdir -p "$fx"; export PR_LAND_NOW=2026-11-24T12:00:00Z; }
withnotif() { mkdir -p "$XDG_CONFIG_HOME/pr-land"; printf 'NOTIFY_CMD=%s\n' "$tmp/notify.sh" >"$XDG_CONFIG_HOME/pr-land/notify.conf"; }
run() { out="$("$@" 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"; }
pl() { run bash "$script" "$@"; }
sf() { echo "$sd/${1%%/*}__${1##*/}__$2.json"; }
sget() { jq -r ".$2 | if . == null then \"\" else tostring end" "$1"; }
nlog() { cat "$sd/notices.log" 2>/dev/null; }
nlines() { nlog | wc -l; }
# resp PR STATE DRAFT HEAD BASE MERGEABLE REVIEW ROLLUP
resp() { jq -n --arg s "$2" --argjson d "$3" --arg h "$4" --arg b "$5" --arg m "$6" --arg r "$7" --argjson c "$8" \
  '{state:$s,isDraft:$d,headRefOid:$h,baseRefName:$b,mergeable:$m,reviewDecision:$r,statusCheckRollup:$c}' >"$fx/resp-$1.json"; }
cr() { printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":"%s"}' "$1" "$2" "$3"; }
sc() { printf '{"__typename":"StatusContext","context":"%s","state":"%s"}' "$1" "$2"; }
GOOD="[$(cr build COMPLETED SUCCESS),$(cr lint COMPLETED NEUTRAL),$(cr docs COMPLETED SKIPPED)]"
# mkstate REPO PR SHA BASE ARMED STATUS
mkstate() { mkdir -p "$sd"; jq -n --arg repo "$1" --argjson pr "$2" --arg sha "$3" --arg base "$4" --arg at "$5" --arg st "$6" \
  '{repo:$repo,pr:$pr,sha:$sha,base:$base,armed_at:$at,status:$st,gh_failures:0,gh_alerted:false,pending_msg:""}' >"$(sf "$1" "$2")"; }

# waitfor FILE: poll every 0.05 s for up to 10 s
waitfor() { local _i; for _i in $(seq 1 200); do [ -e "$1" ] && return 0; sleep 0.05; done; return 1; }

# ---------- usage and environment ----------
fresh
pl; check "no arguments: usage, exit 10" '[ $rc -eq 10 ] && grep -qi usage <<<"$err"' "rc=$rc err=[$err]"
pl bogus; check "unknown command: usage, exit 10" '[ $rc -eq 10 ] && grep -qi usage <<<"$err"' "rc=$rc err=[$err]"
run env PATH="$tmp/empty" /bin/bash "$script" list; check "missing gh: exit 10" '[ $rc -eq 10 ]' "rc=$rc"
mkdir -p "$tmp/onlygh"; cp "$fakebin/gh" "$tmp/onlygh/gh"
run env PATH="$tmp/onlygh" /bin/bash "$script" list; check "missing jq: exit 10" '[ $rc -eq 10 ]' "rc=$rc"

# ---------- arm ----------
fresh; resp 7 OPEN false $S1 main MERGEABLE "" "[]"
pl arm $R 7 --sha $S1
check "arm ok: line and exit 0" '[ $rc -eq 0 ] && [ "$out" = "PR-LAND $R#7 armed sha=$S1" ]' "rc=$rc out=[$out] err=[$err]"
f="$(sf $R 7)"
check "arm ok: state file fields" '[ "$(sget "$f" repo)" = $R ] && [ "$(sget "$f" pr)" = 7 ] && [ "$(sget "$f" sha)" = $S1 ] && [ "$(sget "$f" base)" = main ] && [ "$(sget "$f" status)" = armed ] && [ "$(sget "$f" armed_at)" = 2026-11-24T12:00:00Z ] && [ "$(sget "$f" gh_failures)" = 0 ]' "$(cat "$f" 2>/dev/null)"
check "arm ok: exactly one gh pr view with the contract argv" '[ "$(cat "$fx/calls.log")" = "pr view 7 -R $R --json state,isDraft,headRefOid,baseRefName" ]' "$(cat "$fx/calls.log")"

fresh; resp 7 OPEN false $S1 main MERGEABLE "" "[]"
pl arm $R 7 --sha "${S1:0:7}"
check "arm with a short sha pins the full head" '[ $rc -eq 0 ] && [ "$(sget "$(sf $R 7)" sha)" = $S1 ]' "rc=$rc out=[$out]"

fresh; resp 7 CLOSED false $S1 main MERGEABLE "" "[]"
pl arm $R 7 --sha $S1; check "arm refused: closed" '[ $rc -eq 1 ] && [ ! -e "$(sf $R 7)" ]' "rc=$rc"
resp 7 MERGED false $S1 main MERGEABLE "" "[]"
pl arm $R 7 --sha $S1; check "arm refused: merged" '[ $rc -eq 1 ] && [ ! -e "$(sf $R 7)" ]' "rc=$rc"
resp 7 OPEN true $S1 main MERGEABLE "" "[]"
pl arm $R 7 --sha $S1; check "arm refused: draft" '[ $rc -eq 1 ] && [ ! -e "$(sf $R 7)" ]' "rc=$rc"
resp 7 OPEN false $S2 main MERGEABLE "" "[]"
pl arm $R 7 --sha $S1; check "arm refused: head does not start with --sha" '[ $rc -eq 1 ] && [ ! -e "$(sf $R 7)" ]' "rc=$rc"

fresh; resp 7 OPEN false $S1 main MERGEABLE "" "[]"
for a in "$R 7" "$R 7 --sha" "$R 7 --sha abc12" "$R 7 --sha zzzzzzzz" "$R 7 --sha ${S1}0" "bad 7 --sha $S1" "$R 0 --sha $S1" "$R x7 --sha $S1" "$R 7 --sha $S1 --bogus" "$R"; do
  # shellcheck disable=SC2086
  pl arm $a
  check "arm bad arguments exit 10 with usage, no state: [$a]" '[ $rc -eq 10 ] && grep -qi usage <<<"$err" && [ ! -d "$sd" -o -z "$(ls "$sd" 2>/dev/null)" ]' "rc=$rc err=[$err]"
done
check "arm bad arguments never call gh" '[ ! -e "$fx/calls.log" ]'

fresh; resp 7 OPEN false $S1 main MERGEABLE "" "[]"
pl arm $R 7 --sha $S1; PR_LAND_NOW=2026-11-24T13:00:00Z pl arm $R 7 --sha $S1
check "arm twice, same sha: no-op success" '[ $rc -eq 0 ] && [ "$out" = "PR-LAND $R#7 armed sha=$S1" ] && [ "$(sget "$(sf $R 7)" armed_at)" = 2026-11-24T12:00:00Z ] && [ "$(ls "$sd" | wc -l)" = 1 ]' "rc=$rc out=[$out]"
resp 7 OPEN false $S2 main MERGEABLE "" "[]"
pl arm $R 7 --sha $S2
check "arm with a different sha is refused" '[ $rc -eq 1 ] && [ "$(sget "$(sf $R 7)" sha)" = $S1 ]' "rc=$rc"
pl arm $R 7 --sha $S2 --rearm
check "arm --rearm accepts the different sha" '[ $rc -eq 0 ] && [ "$out" = "PR-LAND $R#7 armed sha=$S2" ] && [ "$(sget "$(sf $R 7)" sha)" = $S2 ]' "rc=$rc out=[$out]"

# ---------- sweep: one scenario per rule ----------
A1H=2026-11-24T11:00:00Z
# scenario NAME STATE DRAFT HEAD BASE MERGEABLE ROLLUP ARMED WANT-STATUS [NOTICE-REGEX]
scenario() {
  fresh; withnotif
  mkstate $R 7 $S1 main "$8" armed
  resp 7 "$2" "$3" "$4" "$5" "$6" APPROVED "$7"
  pl sweep
  # shellcheck disable=SC2034  # nre is read inside the eval in check
  local f want="$9" nre="${10:-$9 sha=$S1}"; f="$(sf $R 7)"
  if [ "$want" = armed ]; then
    check "sweep $1: stays armed, no notice" '[ $rc -eq 0 ] && [ "$(sget "$f" status)" = armed ] && [ "$(nlines)" = 0 ] && [ ! -e "$NOTIF_LOG" ]' "rc=$rc status=$(sget "$f" status) notices=[$(nlog)]"
  else
    check "sweep $1: terminal $want, exactly one notice" '[ $rc -eq 0 ] && [ "$(sget "$f" status)" = "$want" ] && [ "$(nlines)" = 1 ] && grep -Eq "PR-LAND $R#7 $nre" <<<"$(nlog)" && [ "$(wc -l <"$NOTIF_LOG")" = 1 ] && [ "$(cat "$NOTIF_LOG.argc")" = 1 ]' "rc=$rc status=$(sget "$f" status) notices=[$(nlog)] notif=[$(cat "$NOTIF_LOG" 2>/dev/null)]"
  fi
}
scenario ready OPEN false $S1 main MERGEABLE "$GOOD" $A1H ready
check "ready notice is the exact review line plus the exact merge command text" '[ "$(cut -d" " -f2- <<<"$(nlog)")" = "PR-LAND $R#7 ready sha=$S1 review=APPROVED : gh pr merge 7 -R $R --squash --match-head-commit $S1" ] && [ "$(cat "$NOTIF_LOG")" = "PR-LAND $R#7 ready sha=$S1 review=APPROVED : gh pr merge 7 -R $R --squash --match-head-commit $S1" ]' "$(nlog)"
check "ready: only gh pr view was called, once" '[ "$(cat "$fx/calls.log")" = "pr view 7 -R $R --json state,isDraft,headRefOid,baseRefName,mergeable,reviewDecision,statusCheckRollup" ]' "$(cat "$fx/calls.log")"
check "notices.log lines carry a UTC timestamp" 'grep -Eq "^2026-11-24T12:00:00Z PR-LAND " "$sd/notices.log"' "$(nlog)"
# review "none"
fresh; withnotif; mkstate $R 7 $S1 main $A1H armed; resp 7 OPEN false $S1 main MERGEABLE "" "$GOOD"; pl sweep
check "ready with no review decision says review=none" 'grep -q "review=none : gh pr merge 7" <<<"$(nlog)"' "$(nlog)"
# status contexts count too
scenario "ready with a SUCCESS status context" OPEN false $S1 main MERGEABLE "[$(cr build COMPLETED SUCCESS),$(sc ci/x SUCCESS)]" $A1H ready
scenario expired OPEN false $S1 main MERGEABLE "$GOOD" 2026-11-21T11:00:00Z expired
check "expired made no gh call" '[ ! -e "$fx/calls.log" ]'
scenario closed CLOSED false $S1 main MERGEABLE "$GOOD" $A1H closed
scenario merged-elsewhere MERGED false $S1 main MERGEABLE "$GOOD" $A1H closed
scenario head-changed OPEN false $S2 main MERGEABLE "$GOOD" $A1H head-changed "head-changed sha=$S1 new=$S2 : pr-land arm $R 7 --sha $S2"
scenario base-changed OPEN false $S1 develop MERGEABLE "$GOOD" $A1H base-changed
scenario draft OPEN true $S1 main MERGEABLE "$GOOD" $A1H draft
scenario failed OPEN false $S1 main MERGEABLE "[$(cr lint COMPLETED SUCCESS),$(cr build COMPLETED FAILURE),$(cr test COMPLETED CANCELLED)]" $A1H "failed:build"
for c in CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE; do
  scenario "failed ($c)" OPEN false $S1 main MERGEABLE "[$(cr t COMPLETED $c)]" $A1H "failed:t"
done
scenario "failed (status context ERROR)" OPEN false $S1 main MERGEABLE "[$(sc ci/x ERROR)]" $A1H "failed:ci/x"
scenario "failure beats pending" OPEN false $S1 main MERGEABLE "[$(cr a IN_PROGRESS ''),$(cr b COMPLETED FAILURE)]" $A1H "failed:b"
scenario pending OPEN false $S1 main MERGEABLE "[$(cr a IN_PROGRESS ''),$(cr b COMPLETED SUCCESS)]" $A1H armed
scenario "pending status context" OPEN false $S1 main MERGEABLE "[$(sc ci/x PENDING)]" $A1H armed
scenario "no checks, 14 minutes after arming" OPEN false $S1 main MERGEABLE "[]" 2026-11-24T11:46:00Z armed
scenario "no checks, 16 minutes after arming" OPEN false $S1 main MERGEABLE "[]" 2026-11-24T11:44:00Z no-checks
scenario not-mergeable OPEN false $S1 main CONFLICTING "$GOOD" $A1H not-mergeable
scenario "mergeable UNKNOWN" OPEN false $S1 main UNKNOWN "$GOOD" $A1H armed

# ---------- gh failures ----------
fresh; withnotif; mkstate $R 7 $S1 main $A1H armed
echo "HTTP 401: Bad credentials (ghp_abcdefghijklmnopqrstuvwxyz0123456789) - run gh auth login" >"$fx/fail-7.txt"
f="$(sf $R 7)"
pl sweep; pl sweep
check "gh failing twice: still armed, failures=2, no notice" '[ "$(sget "$f" status)" = armed ] && [ "$(sget "$f" gh_failures)" = 2 ] && [ "$(nlines)" = 0 ]' "$(cat "$f")"
pl sweep
check "third failure sends one gh-error:auth notice" '[ "$(sget "$f" gh_failures)" = 3 ] && [ "$(sget "$f" gh_alerted)" = true ] && [ "$(nlines)" = 1 ] && grep -q "PR-LAND $R#7 gh-error:auth" <<<"$(nlog)" && [ "$(wc -l <"$NOTIF_LOG")" = 1 ]' "$(nlog)"
pl sweep
check "fourth failure sends no second notice" '[ "$(sget "$f" gh_failures)" = 4 ] && [ "$(nlines)" = 1 ] && [ "$(wc -l <"$NOTIF_LOG")" = 1 ] && [ "$(sget "$f" status)" = armed ]' "$(nlog)"
check "no token text in the log, the notifier, the state or the output" '! grep -rq "ghp_" "$sd" "$NOTIF_LOG" && ! grep -q "ghp_" <<<"$out$err"'
rm "$fx/fail-7.txt"; resp 7 OPEN false $S1 main MERGEABLE "" "[$(cr a IN_PROGRESS '')]"
pl sweep
check "a later success clears failures and the alert" '[ "$(sget "$f" gh_failures)" = 0 ] && [ "$(sget "$f" gh_alerted)" = false ] && [ "$(sget "$f" status)" = armed ]' "$(cat "$f")"
fresh; mkstate $R 7 $S1 main $A1H armed; echo "GraphQL: Could not resolve to a PullRequest (404)" >"$fx/fail-7.txt"
pl sweep; pl sweep; pl sweep
check "notfound class" 'grep -q "PR-LAND $R#7 gh-error:notfound" <<<"$(nlog)"' "$(nlog)"
fresh; mkstate $R 7 $S1 main $A1H armed; echo "connection reset" >"$fx/fail-7.txt"
pl sweep; pl sweep; pl sweep
check "other class" 'grep -q "PR-LAND $R#7 gh-error:gh" <<<"$(nlog)"' "$(nlog)"

# ---------- notifier ----------
fresh; withnotif; touch "$NOTIF_FAIL"; mkstate $R 7 $S1 main $A1H armed; resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"
pl sweep; f="$(sf $R 7)"
check "notifier failing: notice logged, pending_msg stored, still terminal" '[ $rc -eq 0 ] && [ "$(sget "$f" status)" = ready ] && [ "$(nlines)" = 1 ] && grep -q "PR-LAND $R#7 ready" <<<"$(sget "$f" pending_msg)"' "$(cat "$f")"
rm -f "$NOTIF_FAIL"; pl sweep
check "next sweep delivers the pending notice and clears it" '[ -z "$(sget "$f" pending_msg)" ] && [ "$(wc -l <"$NOTIF_LOG")" = 1 ] && grep -q "PR-LAND $R#7 ready" "$NOTIF_LOG" && [ "$(nlines)" = 1 ]' "$(cat "$f") notif=[$(cat "$NOTIF_LOG" 2>/dev/null)]"
pl sweep; check "a delivered notice is not sent again" '[ "$(wc -l <"$NOTIF_LOG")" = 1 ]'
fresh; mkstate $R 7 $S1 main $A1H armed; resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"
pl sweep
check "no notifier configured: the log line is the notice, no error" '[ $rc -eq 0 ] && [ "$(nlines)" = 1 ] && [ -z "$(sget "$(sf $R 7)" pending_msg)" ]'
fresh; mkdir -p "$XDG_CONFIG_HOME/pr-land"; echo "NOTIFY_CMD=$tmp/does-not-exist" >"$XDG_CONFIG_HOME/pr-land/notify.conf"
mkstate $R 7 $S1 main $A1H armed; resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"; pl sweep
check "missing notifier executable: pending_msg stored" '[ -n "$(sget "$(sf $R 7)" pending_msg)" ] && [ "$(nlines)" = 1 ]'
fresh; mkdir -p "$XDG_CONFIG_HOME/pr-land"; echo "NOTIFY_CMD=relative/notify.sh" >"$XDG_CONFIG_HOME/pr-land/notify.conf"
mkstate $R 7 $S1 main $A1H armed; resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"; pl sweep
check "relative notifier path is refused: pending_msg stored" '[ -n "$(sget "$(sf $R 7)" pending_msg)" ]'

# ---------- forged and broken state files ----------
fresh; withnotif; mkdir -p "$sd"
jq -n '{repo:"octo/demo;touch '"$tmp"'/pwned",pr:7,sha:"'$S1'",base:"main",armed_at:"2026-11-24T11:00:00Z",status:"armed"}' >"$sd/octo__demo__7.json"
jq -n '{repo:"$(touch '"$tmp"'/pwned2)/x",pr:8,sha:"'$S1'",base:"main",armed_at:"2026-11-24T11:00:00Z",status:"armed"}' >"$sd/a__b__8.json"
jq -n '{repo:"octo/demo",pr:"9;touch '"$tmp"'/pwned3",sha:"'$S1'",base:"main",armed_at:"2026-11-24T11:00:00Z",status:"armed"}' >"$sd/a__b__9.json"
jq -n '{repo:"octo/demo",pr:10,sha:"$(touch '"$tmp"'/pwned4)",base:"main",armed_at:"2026-11-24T11:00:00Z",status:"armed"}' >"$sd/a__b__10.json"
pl sweep
check "forged state files: skipped with a stderr line, nothing executed, files kept, no gh call, exit 0" '[ $rc -eq 0 ] && [ ! -e "$tmp/pwned" ] && [ ! -e "$tmp/pwned2" ] && [ ! -e "$tmp/pwned3" ] && [ ! -e "$tmp/pwned4" ] && [ "$(grep -c . <<<"$err")" -ge 4 ] && [ "$(ls "$sd"/*.json | wc -l)" = 4 ] && [ ! -e "$fx/calls.log" ] && [ "$(nlines)" = 0 ]' "rc=$rc err=[$err]"
fresh; mkdir -p "$sd"; echo '{not json' >"$sd/bad__json__1.json"; echo '{"repo":"octo/demo","pr":1}' >"$sd/octo__demo__1.json"
mkstate $R 7 $S1 main $A1H armed; resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"
pl sweep
check "invalid JSON and missing fields: skipped, kept, the valid file still processed" '[ $rc -eq 0 ] && [ "$(cat "$sd/bad__json__1.json")" = "{not json" ] && [ -e "$sd/octo__demo__1.json" ] && [ "$(sget "$(sf $R 7)" status)" = ready ] && [ "$(grep -c . <<<"$err")" -ge 2 ]' "rc=$rc err=[$err]"

# ---------- concurrent sweeps ----------
fresh; mkstate $R 7 $S1 main $A1H armed; resp 7 OPEN false $S1 main MERGEABLE APPROVED "[$(cr a IN_PROGRESS '')]"
rel="$tmp/release1"; rm -f "$rel"
( FAKE_GH_RELEASE="$rel" bash "$script" sweep >"$tmp/first.out" 2>&1; echo $? >"$tmp/first.rc" ) &
bg=$!
waitfor "$fx/entered" || bad "first sweep reached gh" "marker never appeared"
pl sweep
check "second concurrent sweep is skipped at once, exit 0" '[ $rc -eq 0 ] && grep -qi skipped <<<"$out"' "rc=$rc out=[$out]"
: >"$rel"; wait "$bg"
check "first sweep finished normally while the second was skipped" '[ "$(cat "$tmp/first.rc")" = 0 ] && [ -z "$(cat "$tmp/first.out")" ]' "rc=$(cat "$tmp/first.rc" 2>/dev/null) out=[$(cat "$tmp/first.out")]"
check "only the first sweep called gh" '[ "$(wc -l <"$fx/calls.log")" = 1 ]'

# ---------- list and cancel ----------
fresh; mkstate $R 7 $S1 main $A1H armed; mkstate octo/other 9 $S2 main 2026-11-20T10:00:00Z ready
mkstate octo/old 3 $S1 main 2026-10-01T10:00:00Z ready
jq '.closed_at="2026-10-02T10:00:00Z"' "$(sf octo/old 3)" >"$tmp/o.json" && mv "$tmp/o.json" "$(sf octo/old 3)"
pl list
check "list: one line per state file with repo, PR, short sha, status, armed time" '[ $rc -eq 0 ] && grep -Eq "^$R +7 +1111111 +armed +2026-11-24T11:00:00Z" <<<"$out" && grep -Eq "^octo/other +9 +2222222 +ready +2026-11-20T10:00:00Z" <<<"$out"' "rc=$rc out=[$out]"
check "list ignores terminal files older than 14 days" '! grep -q "octo/old" <<<"$out"' "$out"
check "old terminal file is not deleted" '[ -e "$(sf octo/old 3)" ]'
pl cancel $R 7
check "cancel marks the file cancelled" '[ $rc -eq 0 ] && [ "$(sget "$(sf $R 7)" status)" = cancelled ]' "rc=$rc out=[$out]"
pl cancel octo/nothing 1; check "cancel of an unknown target exits 1" '[ $rc -eq 1 ]' "rc=$rc"
pl sweep; check "a cancelled file is not swept" '[ ! -e "$fx/calls.log" ]'
pl cancel; check "cancel without arguments: usage, exit 10" '[ $rc -eq 10 ]' "rc=$rc"

# ---------- review fixes ----------
# hostile check names: the verdict must come from structured data, never from a name
san() { printf '%s' "$1" | tr -c 'A-Za-z0-9 ._:/()@+-' '_' | cut -c1-80; }
# shellcheck disable=SC2034  # exp is read inside the eval in check
hostile() {  # NAME-LABEL CHECK-NAME CONCLUSION-STATUS: failing (FAILURE) or pending (IN_PROGRESS)
  fresh; withnotif; mkstate $R 7 $S1 main $A1H armed
  local roll; roll="$(jq -nc --arg n "$2" --arg st "$3" '[{"__typename":"CheckRun",name:$n,status:(if $st=="FAILURE" then "COMPLETED" else $st end),conclusion:(if $st=="FAILURE" then "FAILURE" else "" end)},{"__typename":"CheckRun",name:"ok",status:"COMPLETED",conclusion:"SUCCESS"}]')"
  resp 7 OPEN false $S1 main MERGEABLE APPROVED "$roll"
  pl sweep
  local f exp; f="$(sf $R 7)"; exp="failed:$(san "$2")"
  if [ "$3" = FAILURE ]; then
    check "hostile name ($1): failed:<sanitised>, never ready, one-line notice" '[ "$(sget "$f" status)" = "$exp" ] && [ "$(nlines)" = 1 ] && [ "$(wc -l <"$NOTIF_LOG")" = 1 ] && ! grep -q " ready " <<<"$(nlog)"' "status=$(sget "$f" status) notices=[$(nlog)]"
  else
    check "hostile name ($1): pending check keeps it armed, no notice" '[ "$(sget "$f" status)" = armed ] && [ "$(nlines)" = 0 ]' "status=$(sget "$f" status) notices=[$(nlog)]"
  fi
  check "hostile name ($1): nothing executed" '[ ! -e "$tmp/pwn5" ]'
}
hostile newline $'build\nx' FAILURE
hostile separator $'build\001x' FAILURE
hostile "separator then newline" $'\001\n' FAILURE
hostile injection "\"; rm -rf x # \`touch $tmp/pwn5\` \$(touch $tmp/pwn5)" FAILURE
hostile long "$(printf 'a%.0s' $(seq 1 500))" FAILURE
hostile "pending newline" $'lint\nx' IN_PROGRESS
hostile "pending separator" $'lint\001x' IN_PROGRESS

# arm never deletes a file it cannot vouch for
fresh; resp 7 OPEN false $S1 main MERGEABLE "" "[]"; mkdir -p "$sd"; printf '{not json' >"$(sf $R 7)"
pl arm $R 7 --sha $S1
check "arm over an invalid-JSON file is refused and the bytes are unchanged" '[ $rc -eq 1 ] && [ "$(cat "$(sf $R 7)")" = "{not json" ] && grep -q "octo__demo__7.json" <<<"$err"' "rc=$rc err=[$err]"
echo '{"repo":"octo/demo"}' >"$(sf $R 7)"; pl arm $R 7 --sha $S1
check "arm over a file lacking fields is refused and kept" '[ $rc -eq 1 ] && [ "$(cat "$(sf $R 7)")" = "{\"repo\":\"octo/demo\"}" ]' "rc=$rc"
mkstate $R 7 $S2 main $A1H ready
pl arm $R 7 --sha $S1
check "arm over a valid terminal file succeeds" '[ $rc -eq 0 ] && [ "$(sget "$(sf $R 7)" status)" = armed ] && [ "$(sget "$(sf $R 7)" sha)" = $S1 ]' "rc=$rc err=[$err]"

# one lock for arm, cancel and sweep
fresh; resp 7 OPEN false $S1 main MERGEABLE "" "[]"; mkdir -p "$sd"
rel="$tmp/release2"; rm -f "$rel" "$tmp/locked"
( flock 8; : >"$tmp/locked"; for _ in $(seq 1 400); do [ -e "$rel" ] && break; sleep 0.05; done ) 8>"$sd/.lock" & lk=$!
waitfor "$tmp/locked" || bad "holder took the lock" "marker never appeared"
PR_LAND_LOCK_WAIT=1 pl arm $R 7 --sha $S1
check "arm waits for the lock, then exits 1 with a message and writes nothing" '[ $rc -eq 1 ] && [ -n "$err" ] && [ ! -e "$(sf $R 7)" ]' "rc=$rc err=[$err]"
mkstate $R 8 $S1 main $A1H armed
PR_LAND_LOCK_WAIT=1 pl cancel $R 8
check "cancel waits for the lock, then exits 1, state unchanged" '[ $rc -eq 1 ] && [ "$(sget "$(sf $R 8)" status)" = armed ]' "rc=$rc err=[$err]"
pl sweep; check "sweep skips at once while the lock is held" '[ $rc -eq 0 ] && grep -qi skipped <<<"$out"' "rc=$rc out=[$out]"
check "arm and cancel ran while the holder still held the lock" '[ ! -e "$rel" ]'
: >"$rel"; wait "$lk"
PR_LAND_LOCK_WAIT=5 pl arm $R 7 --sha $S1; check "arm succeeds once the lock is free" '[ $rc -eq 0 ]' "rc=$rc err=[$err]"

# pending_msg read back from a state file is untrusted
fresh; withnotif; mkstate $R 7 $S1 main $A1H ready
jq --arg m $'PR-LAND octo/demo#7 ready\nrm -rf /\001tail' '.pending_msg=$m' "$(sf $R 7)" >"$tmp/p.json" && mv "$tmp/p.json" "$(sf $R 7)"
pl sweep
check "forged multi-line pending_msg is delivered as one sanitised line" '[ "$(wc -l <"$NOTIF_LOG")" = 1 ] && [ "$(cat "$NOTIF_LOG")" = "PR-LAND octo/demo#7 readyrm -rf /tail" ] && [ -z "$(sget "$(sf $R 7)" pending_msg)" ]' "notif=[$(cat "$NOTIF_LOG" 2>/dev/null)]"
fresh; withnotif; mkstate $R 7 $S1 main $A1H ready
jq '.pending_msg="rm -rf / not a notice"' "$(sf $R 7)" >"$tmp/p.json" && mv "$tmp/p.json" "$(sf $R 7)"
pl sweep
check "pending_msg not starting with PR-LAND is dropped with a stderr line and cleared" '[ ! -e "$NOTIF_LOG" ] && [ -z "$(sget "$(sf $R 7)" pending_msg)" ] && [ -n "$err" ]' "err=[$err]"
fresh; withnotif; mkstate $R 7 $S1 main $A1H ready
jq --arg m "PR-LAND $(printf 'x%.0s' $(seq 1 900))" '.pending_msg=$m' "$(sf $R 7)" >"$tmp/p.json" && mv "$tmp/p.json" "$(sf $R 7)"
pl sweep
check "pending_msg is capped at 500 characters" '[ "$(wc -c <"$NOTIF_LOG")" -le 501 ]' "$(wc -c <"$NOTIF_LOG")"

# head missing from gh's JSON is a gh failure, not head-changed
fresh; withnotif; mkstate $R 7 $S1 main $A1H armed
jq -n '{state:"OPEN",isDraft:false,baseRefName:"main",mergeable:"MERGEABLE",reviewDecision:"",statusCheckRollup:[]}' >"$fx/resp-7.json"
pl sweep
check "missing headRefOid: stays armed, counted as a gh failure, no notice" '[ "$(sget "$(sf $R 7)" status)" = armed ] && [ "$(sget "$(sf $R 7)" gh_failures)" = 1 ] && [ "$(nlines)" = 0 ]' "$(cat "$(sf $R 7)")"
resp 7 OPEN false "nothex" main MERGEABLE "" "[]"; pl sweep
check "non-hex headRefOid: counted as a gh failure" '[ "$(sget "$(sf $R 7)" status)" = armed ] && [ "$(sget "$(sf $R 7)" gh_failures)" = 2 ]'

# PR_LAND_NOW invalid
fresh
PR_LAND_NOW=garbage pl list; check "invalid PR_LAND_NOW exits 10 with a message" '[ $rc -eq 10 ] && [ -n "$err" ]' "rc=$rc err=[$err]"
PR_LAND_NOW=tomorrow pl list; check "PR_LAND_NOW must be an ISO timestamp" '[ $rc -eq 10 ]' "rc=$rc"

# error class comes from specific phrases only
fresh; mkstate $R 7 $S1 main $A1H armed; echo "stream reset, token bucket refilled 401 times" >"$fx/fail-7.txt"
pl sweep; pl sweep; pl sweep
check "unrelated text with 401 and token is classed gh" 'grep -q "PR-LAND $R#7 gh-error:gh\$" <<<"$(nlog)"' "$(nlog)"

# ---------- fail closed: input shapes ----------
GOODJSON="$(jq -nc --arg h "$S1" --argjson r "$GOOD" '{state:"OPEN",isDraft:false,headRefOid:$h,baseRefName:"main",mergeable:"MERGEABLE",reviewDecision:"APPROVED",statusCheckRollup:$r}')"
# shape LABEL JQ-FILTER ARMED-AT WANT [FAILURES]: WANT is a status, or "armed" (then FAILURES is the expected gh_failures)
shape() {
  fresh; withnotif; mkstate $R 7 $S1 main "$3" armed
  jq -c "$2" <<<"$GOODJSON" >"$fx/resp-7.json"
  pl sweep
  # shellcheck disable=SC2034  # want and nfl are read inside the evals in check
  local f st want="$4" nfl="${5:-0}"; f="$(sf $R 7)"; st="$(sget "$f" status)"
  if [ "$want" = armed ]; then
    check "shape $1: stays armed, gh_failures=$nfl, never ready" '[ "$st" = armed ] && [ "$(sget "$f" gh_failures)" = "$nfl" ] && [ "$(nlines)" = 0 ]' "status=$st failures=$(sget "$f" gh_failures) notices=[$(nlog)]"
  else
    check "shape $1: $want, one-line notice, never ready" '[ "$st" = "$want" ] && [ "$(nlines)" = 1 ] && [ "$(wc -l <"$NOTIF_LOG")" = 1 ] && ! grep -q " ready " <<<"$(nlog)"' "status=$st notices=[$(nlog)]"
  fi
}
shape "status context with a newline in its name" '.statusCheckRollup=[{"__typename":"StatusContext",context:"ci\nx",state:"FAILURE"}]' $A1H "failed:ci_x"
shape "hostile base branch in the reply" '.baseRefName="ma\nin; rm -rf x `touch '"$tmp"'/pwn6`"' $A1H base-changed
check "hostile base: nothing executed" '[ ! -e "$tmp/pwn6" ]'
shape "failed entry with a null name" '.statusCheckRollup=[{"__typename":"CheckRun",name:null,status:"COMPLETED",conclusion:"FAILURE"}]' $A1H "failed:check"
shape "null rollup, 14 minutes" '.statusCheckRollup=null' 2026-11-24T11:46:00Z armed
shape "missing rollup key, 14 minutes" 'del(.statusCheckRollup)' 2026-11-24T11:46:00Z armed
shape "null rollup, 16 minutes" '.statusCheckRollup=null' 2026-11-24T11:44:00Z no-checks
shape "missing rollup key, 16 minutes" 'del(.statusCheckRollup)' 2026-11-24T11:44:00Z no-checks
shape "entry with neither conclusion nor state" '.statusCheckRollup=[{"__typename":"CheckRun",name:"x"}]' $A1H armed
shape "no state key" 'del(.state)' $A1H armed 1
shape "state WEIRD" '.state="WEIRD"' $A1H armed 1
shape "no isDraft key" 'del(.isDraft)' $A1H armed 1
shape "rollup is a string" '.statusCheckRollup="oops"' $A1H armed 1
shape "isDraft is a string" '.isDraft="false"' $A1H armed 1
shape "all green but mergeable missing" 'del(.mergeable)' $A1H armed
shape "all green but mergeable null" '.mergeable=null' $A1H armed

# a long base name is capped at arm time like at sweep time
fresh; withnotif; long="b$(printf 'x%.0s' $(seq 1 149))"
resp 7 OPEN false $S1 "$long" MERGEABLE APPROVED "$GOOD"
pl arm $R 7 --sha $S1
check "arm with a 150-character base succeeds" '[ $rc -eq 0 ]' "rc=$rc err=[$err]"
pl sweep
check "150-character base armed then swept unchanged is not base-changed" '[ "$(sget "$(sf $R 7)" status)" = ready ]' "status=$(sget "$(sf $R 7)" status) notices=[$(nlog)]"

# ---------- the whole suite: gh was only ever asked to view ----------
check "gh was called during the suite" '[ -s "$GH_ALL_LOG" ]'
check "recorded gh argv log contains only pr view calls" '[ "$(grep -vc "^pr view " "$GH_ALL_LOG")" = 0 ]' "$(grep -v '^pr view ' "$GH_ALL_LOG" | head -3)"
check "recorded gh argv log has no merge, ready, comment, review, close or api" '! grep -Eqw "merge|ready|comment|review|close|api" "$GH_ALL_LOG"'

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
