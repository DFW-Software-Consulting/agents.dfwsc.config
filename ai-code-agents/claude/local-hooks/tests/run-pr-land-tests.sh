#!/usr/bin/env bash
# CLI tests for bin/pr-land (notify-only: it never merges). The seam is the command line:
# arguments, exit code, stdout lines, and the state files and notices.log it leaves.
# A fake `gh` is first on PATH, replays canned JSON per PR number and records every argv
# it is called with; a fake notifier records what it is given. HOME and the XDG
# directories are throwaway. "Now" is PR_LAND_NOW. No network, no real gh, no real config.
# The tool pins the environment of every gh and notifier call (env -i plus a pass-list), so the
# fakes get their paths baked in at generation time. Test seams (PR_LAND_NOW, PR_LAND_LOCK_WAIT,
# PR_LAND_GH_PATH) need PR_LAND_TEST=1; `pl` sets it and the fake gh directory. A counting
# `timeout` shim sits first on PATH: it logs every gh call the script makes, refuses to run any
# gh but the fake, and so doubles as the tripwire against a real gh ever running.
# Hermetic start: nothing inherited from the caller can change what the suite does, except the one
# documented override PR_LAND_SCRIPT (the script under test, for mutation proofs on a scratch copy).
# Usage: local-hooks/tests/run-pr-land-tests.sh
set -uo pipefail
for _v in $(compgen -v); do case "$_v" in GH_*|GIT_*) unset "$_v" ;; esac; done
unset _v SHIM_BLOCK PR_LAND_NOW PR_LAND_LOCK_WAIT PR_LAND_GH_PATH PR_LAND_TEST BASH_ENV ENV GITHUB_TOKEN GH_TOKEN GH_HOST
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
suite="$here/$(basename "${BASH_SOURCE[0]}")"
script="$(cd "$here/../.." && pwd)/bin/pr-land"
if [ -n "${PR_LAND_SCRIPT:-}" ]; then
  if [ ! -f "$PR_LAND_SCRIPT" ] || [ ! -x "$PR_LAND_SCRIPT" ]; then
    echo "run-pr-land-tests: PR_LAND_SCRIPT=$PR_LAND_SCRIPT is not an executable file; refusing to fall back" >&2; exit 2
  fi
  script="$(cd "$(dirname "$PR_LAND_SCRIPT")" && pwd)/$(basename "$PR_LAND_SCRIPT")"
fi
echo "pr-land suite: script under test = $script"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$HOME"
sd="$XDG_STATE_HOME/pr-land"
fx="$tmp/fx"; GH_ALL_LOG="$tmp/gh-all.log"
NOTIF_LOG="$tmp/notif.log"; NOTIF_FAIL="$tmp/notif.fail"; NOTIF_ENV="$tmp/notif.env"; NOTIF_PROBE="$tmp/notif.probe"
SHIM_LOG="$tmp/timeout-shim.log"; M="$tmp/marker"   # no hostile hook may ever create M
export PR_LAND_NOW=2026-11-24T12:00:00Z

fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat >"$fakebin/gh" <<GH
#!/usr/bin/env bash
d="$fx"; all="$GH_ALL_LOG"
GH
cat >>"$fakebin/gh" <<'GH'
printf '%s\n' "$*" >>"$d/calls.log"
printf '%s\n' "$*" >>"$all"
if [ -e "$d/env-probe" ]; then env >"$d/env.log"; fi
if [ -e "$d/hold" ]; then  # handshake: say we are in, then block until released (20 s hard bound)
  : >"$d/entered"
  for _ in $(seq 1 400); do [ -e "$d/release" ] && break; sleep 0.05; done
fi
pr="$3"
if [ -e "$d/fail-$pr.txt" ]; then cat "$d/fail-$pr.txt" >&2; exit 1; fi
[ -e "$d/resp-$pr.json" ] || { echo "fake gh: no fixture for $pr" >&2; exit 1; }
cat "$d/resp-$pr.json"
GH
chmod +x "$fakebin/gh"
cat >"$tmp/notify.sh" <<N
#!/usr/bin/env bash
[ -e "$NOTIF_FAIL" ] && exit 1
[ -e "$NOTIF_PROBE" ] && env >"$NOTIF_ENV"
printf '%s\n' "\$1" >>"$NOTIF_LOG"
printf '%s\n' "\$#" >>"$NOTIF_LOG.argc"
N
chmod +x "$tmp/notify.sh"
# the counting timeout shim: logs "exec|block ARGV" for every call with a gh argument. It runs
# only the fake gh (absolute or bare, found first on PATH); any other gh is blocked, and
# every gh is blocked while SHIM_BLOCK is set. Everything else (the notifier) goes to the real timeout.
shimbin="$tmp/shim"; mkdir -p "$shimbin"
cat >"$shimbin/timeout" <<SH
#!/usr/bin/env bash
log="$SHIM_LOG"; fakegh="$fakebin/gh"
SH
cat >>"$shimbin/timeout" <<'SH'
isgh=0; allow=1
for a in "$@"; do
  case "$a" in
    gh) isgh=1 ;;
    */gh) isgh=1; [ "$a" = "$fakegh" ] || allow=0 ;;
  esac
done
if [ "$isgh" = 1 ]; then
  if [ "$allow" = 1 ] && [ -z "${SHIM_BLOCK:-}" ]; then echo "exec $*" >>"$log"; else echo "block $*" >>"$log"; exit 1; fi
fi
exec /usr/bin/timeout "$@"
SH
chmod +x "$shimbin/timeout"
# a bare `gh` found through the suite's own PATH is a bug in the script: it logs and fails
tripbin="$tmp/trip"; mkdir -p "$tripbin"; TRIP_LOG="$tmp/bare-gh.log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 1\n' "$TRIP_LOG" >"$tripbin/gh"; chmod +x "$tripbin/gh"
export PATH="$shimbin:$tripbin:$PATH"
# the real gh is blocked by the shim; the tests that rely on that need one in the fixed PATH
HAVE_REAL_GH=0; PATH=/usr/local/bin:/usr/bin:/bin command -v gh >/dev/null 2>&1 && HAVE_REAL_GH=1

pass=0; fail=0; skipped=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
skip() { skipped=$((skipped + 1)); echo "SKIP $1: no gh in the fixed PATH"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

R=octo/demo
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
fresh() { rm -rf "$sd" "$XDG_CONFIG_HOME" "$fx" "$NOTIF_LOG" "$NOTIF_LOG.argc" "$NOTIF_FAIL"; mkdir -p "$fx"; export PR_LAND_NOW=2026-11-24T12:00:00Z; }
withnotif() { mkdir -p "$XDG_CONFIG_HOME/pr-land"; printf 'NOTIFY_CMD=%s\n' "$tmp/notify.sh" >"$XDG_CONFIG_HOME/pr-land/notify.conf"; }
run() { out="$("$@" 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"; }
pl() { run env PR_LAND_TEST=1 PR_LAND_GH_PATH="$fakebin" bash "$script" "$@"; }
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
run env PATH="$tmp/empty" PR_LAND_TEST=1 PR_LAND_GH_PATH="$tmp/empty" /bin/bash "$script" list; check "missing gh: exit 10" '[ $rc -eq 10 ]' "rc=$rc"
mkdir -p "$tmp/onlygh"; cp "$fakebin/gh" "$tmp/onlygh/gh"
run env PATH="$tmp/onlygh" PR_LAND_TEST=1 PR_LAND_GH_PATH="$tmp/onlygh" /bin/bash "$script" list; check "missing jq: exit 10" '[ $rc -eq 10 ]' "rc=$rc"

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
: >"$fx/hold"
( PR_LAND_TEST=1 PR_LAND_GH_PATH="$fakebin" bash "$script" sweep >"$tmp/first.out" 2>&1; echo $? >"$tmp/first.rc" ) &
bg=$!
waitfor "$fx/entered" || bad "first sweep reached gh" "marker never appeared"
pl sweep
check "second concurrent sweep is skipped at once, exit 0" '[ $rc -eq 0 ] && grep -qi skipped <<<"$out"' "rc=$rc out=[$out]"
: >"$fx/release"; wait "$bg"
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

# ---------- pinned environment of every gh and notifier call ----------
fresh; withnotif; : >"$fx/env-probe"; : >"$NOTIF_PROBE"; rm -f "$NOTIF_ENV" "$M"
# BASH_ENV is read by every non-interactive bash, including pr-land itself; only the fake gh and
# the fake notifier must not run it
printf 'case "$0" in */gh|*/notify.sh) touch %s ;; esac\n' "$M" >"$tmp/bashenv.sh"
hostile_env() { export GH_HOST=evil.example GH_CONFIG_DIR=/tmp/x GH_REPO=a/b GH_TOKEN=tok GITHUB_TOKEN=tok2 GH_ENTERPRISE_TOKEN=tok3 GH_PAGER=less PAGER=less BROWSER=firefox BASH_ENV="$tmp/bashenv.sh" ENV="$tmp/bashenv.sh" GIT_DIR=/tmp/y GIT_WORK_TREE=/tmp/z; }
clean_env() { unset GH_HOST GH_CONFIG_DIR GH_REPO GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_PAGER PAGER BROWSER BASH_ENV ENV GIT_DIR GIT_WORK_TREE; }
# shellcheck disable=SC2034  # PASSRE is read inside the evals in check
PASSRE='HOME|USER|LOGNAME|LANG|PATH|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|PWD|SHLVL|_|OLDPWD'
# positive control: the same fakes run directly, with BASH_ENV set and no pin, DO run the hook
mkdir -p "$tmp/ctl"; sed "s|^d=.*|d=\"$tmp/ctl\"; all=/dev/null|" "$fakebin/gh" >"$tmp/ctl/gh"; chmod +x "$tmp/ctl/gh"
BASH_ENV="$tmp/bashenv.sh" "$tmp/ctl/gh" pr view 7 >/dev/null 2>&1
check "control: the fake gh run unpinned with BASH_ENV set does run the hook (marker created)" '[ -e "$M" ]'; rm -f "$M"
BASH_ENV="$tmp/bashenv.sh" "$tmp/notify.sh" x >/dev/null 2>&1
check "control: the fake notifier run unpinned with BASH_ENV set does run the hook (marker created)" '[ -e "$M" ]'; rm -f "$M" "$NOTIF_LOG" "$NOTIF_LOG.argc"
resp 7 OPEN false $S1 main MERGEABLE "" "[]"
hostile_env; pl arm $R 7 --sha $S1; clean_env; cp "$fx/env.log" "$tmp/arm.env" 2>/dev/null
check "hostile environment: arm still works through the fake gh" '[ $rc -eq 0 ] && [ -s "$tmp/arm.env" ]' "rc=$rc err=[$err]"
check "arm: gh environment has none of GH_*, GITHUB_*, GIT_*, PAGER, BROWSER, BASH_ENV, ENV, XDG_CONFIG_HOME" '! grep -Eq "^(GH_|GITHUB_|GIT_|PAGER=|BROWSER=|BASH_ENV=|ENV=|XDG_CONFIG_HOME)" "$tmp/arm.env"' "$(cut -d= -f1 "$tmp/arm.env" | tr '\n' ' ')"
check "arm: gh environment is the pass-list only, PATH fixed, LANG=C" '[ -z "$(cut -d= -f1 "$tmp/arm.env" | grep -Evx "$PASSRE")" ] && grep -qx "PATH=/usr/local/bin:/usr/bin:/bin" "$tmp/arm.env" && grep -qx "LANG=C" "$tmp/arm.env" && grep -qx "HOME=$HOME" "$tmp/arm.env"' "$(cut -d= -f1 "$tmp/arm.env" | tr '\n' ' ')"
resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"; rm -f "$fx/env.log"
hostile_env; pl sweep; clean_env
check "hostile environment: the sweep reached ready and the notifier" '[ $rc -eq 0 ] && [ "$(sget "$(sf $R 7)" status)" = ready ] && [ -s "$fx/env.log" ] && [ -s "$NOTIF_ENV" ]' "rc=$rc err=[$err] status=$(sget "$(sf $R 7)" status)"
check "sweep: gh environment has none of GH_*, GITHUB_*, GIT_*, PAGER, BROWSER, BASH_ENV, ENV, XDG_CONFIG_HOME" '! grep -Eq "^(GH_|GITHUB_|GIT_|PAGER=|BROWSER=|BASH_ENV=|ENV=|XDG_CONFIG_HOME)" "$fx/env.log"' "$(cut -d= -f1 "$fx/env.log" | tr '\n' ' ')"
check "sweep: gh environment is the pass-list only, PATH fixed, LANG=C" '[ -z "$(cut -d= -f1 "$fx/env.log" | grep -Evx "$PASSRE")" ] && grep -qx "PATH=/usr/local/bin:/usr/bin:/bin" "$fx/env.log" && grep -qx "LANG=C" "$fx/env.log"' "$(cut -d= -f1 "$fx/env.log" | tr '\n' ' ')"
check "notifier environment has none of GH_*, GITHUB_*, GIT_*, PAGER, BROWSER, BASH_ENV, ENV, XDG_CONFIG_HOME" '! grep -Eq "^(GH_|GITHUB_|GIT_|PAGER=|BROWSER=|BASH_ENV=|ENV=|XDG_CONFIG_HOME)" "$NOTIF_ENV"' "$(cut -d= -f1 "$NOTIF_ENV" | tr '\n' ' ')"
check "notifier environment is the pass-list only, PATH fixed, LANG=C" '[ -z "$(cut -d= -f1 "$NOTIF_ENV" | grep -Evx "$PASSRE")" ] && grep -qx "PATH=/usr/local/bin:/usr/bin:/bin" "$NOTIF_ENV" && grep -qx "LANG=C" "$NOTIF_ENV"' "$(cut -d= -f1 "$NOTIF_ENV" | tr '\n' ' ')"
check "BASH_ENV script never ran in the fake gh or the fake notifier" '[ ! -e "$M" ]'
rm -f "$NOTIF_PROBE"

# pass-through: the pass-list variables reach the fake gh and the fake notifier unchanged
fresh; withnotif; : >"$fx/env-probe"; : >"$NOTIF_PROBE"; rm -f "$NOTIF_ENV"
resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"; mkstate $R 7 $S1 main $A1H armed
USER=user_marker LOGNAME=logname_marker XDG_RUNTIME_DIR=/run/xrd_marker DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus_marker LANG=de_DE.UTF-8 pl sweep
for ef in "$fx/env.log" "$NOTIF_ENV"; do
  check "pass-through to ${ef##*/}: USER, LOGNAME, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS exactly as given, LANG=C" '[ -s "$ef" ] && grep -qx "USER=user_marker" "$ef" && grep -qx "LOGNAME=logname_marker" "$ef" && grep -qx "XDG_RUNTIME_DIR=/run/xrd_marker" "$ef" && grep -qx "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus_marker" "$ef" && grep -qx "LANG=C" "$ef" && [ "$(grep -c "^LANG=" "$ef")" = 1 ]' "$(cat "$ef" 2>/dev/null | head -12 | tr '\n' ' ')"
done
rm -f "$NOTIF_PROBE"

# HOME is required
fresh
run env -u HOME PR_LAND_TEST=1 PR_LAND_GH_PATH="$fakebin" bash "$script" list
check "HOME unset: exit 10 with a message" '[ $rc -eq 10 ] && grep -q "HOME is not set" <<<"$err"' "rc=$rc err=[$err]"
run env HOME= PR_LAND_TEST=1 PR_LAND_GH_PATH="$fakebin" bash "$script" list
check "HOME empty: exit 10 with a message" '[ $rc -eq 10 ] && grep -q "HOME is not set" <<<"$err"' "rc=$rc err=[$err]"

# the one documented override never falls back silently
run env PR_LAND_SCRIPT="$tmp/no-such-script" bash "$suite"
check "PR_LAND_SCRIPT pointing at a missing file: the suite exits non-zero at once with a message" '[ $rc -ne 0 ] && grep -q "refusing to fall back" <<<"$err" && ! grep -q "^ok " <<<"$out"' "rc=$rc err=[$err]"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/not-exec"
run env PR_LAND_SCRIPT="$tmp/not-exec" bash "$suite"
check "PR_LAND_SCRIPT pointing at a non-executable file: the suite exits non-zero at once with a message" '[ $rc -ne 0 ] && grep -q "refusing to fall back" <<<"$err" && ! grep -q "^ok " <<<"$out"' "rc=$rc err=[$err]"

# ---------- test seams are ignored without PR_LAND_TEST=1 ----------
# No real gh may run: the shim blocks every gh that is not the fake (SHIM_BLOCK blocks them all),
# and logs what the script tried to execute. A far-FUTURE PR_LAND_NOW would expire a fresh entry.
if [ "$HAVE_REAL_GH" = 1 ]; then
nowiso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fresh; withnotif; mkstate $R 7 $S1 main "$nowiso" armed; resp 7 OPEN false $S1 main MERGEABLE APPROVED "$GOOD"
# shellcheck disable=SC2034  # b0 and e0 are read inside the evals in check
b0="$(grep -c '^block ' "$SHIM_LOG" 2>/dev/null)"
# shellcheck disable=SC2034
e0="$(grep -c '^exec ' "$SHIM_LOG" 2>/dev/null)"
run env -u PR_LAND_TEST SHIM_BLOCK=1 PR_LAND_NOW=2099-01-01T00:00:00Z PR_LAND_GH_PATH="$fakebin" bash "$script" sweep
f="$(sf $R 7)"
check "without PR_LAND_TEST a far-future PR_LAND_NOW does not expire a fresh entry" '[ $rc -eq 0 ] && [ "$(sget "$f" status)" = armed ] && [ "$(nlines)" = 0 ]' "rc=$rc status=$(sget "$f" status) notices=[$(nlog)]"
check "without PR_LAND_TEST PR_LAND_GH_PATH is ignored: the fake gh is not called" '[ ! -e "$fx/calls.log" ]'
check "without PR_LAND_TEST the gh the script tried is not under the fake directory" '[ "$(grep -c "^block " "$SHIM_LOG")" -gt "$b0" ] && [ "$(grep -c "^exec " "$SHIM_LOG")" = "$e0" ] && ! grep "^block " "$SHIM_LOG" | tail -n +$((b0 + 1)) | grep -qF "$fakebin"' "$(tail -n 2 "$SHIM_LOG")"
run env -u PR_LAND_TEST PR_LAND_NOW=garbage PR_LAND_GH_PATH="$tmp/nowhere" bash "$script" list
check "without PR_LAND_TEST an invalid PR_LAND_NOW is ignored (no exit 10)" '[ $rc -eq 0 ]' "rc=$rc err=[$err]"
fresh; resp 7 OPEN false $S1 main MERGEABLE "" "[]"
run env -u PR_LAND_TEST SHIM_BLOCK=1 PR_LAND_GH_PATH="$fakebin" bash "$script" arm $R 7 --sha $S1
check "without PR_LAND_TEST arm does not use PR_LAND_GH_PATH: the fake is not called, nothing armed" '[ $rc -eq 1 ] && [ ! -e "$fx/calls.log" ] && [ ! -e "$(sf $R 7)" ]' "rc=$rc err=[$err]"
else
  skip "without PR_LAND_TEST a far-future PR_LAND_NOW does not expire a fresh entry"
  skip "without PR_LAND_TEST PR_LAND_GH_PATH is ignored: the fake gh is not called"
  skip "without PR_LAND_TEST the gh the script tried is not under the fake directory"
  skip "without PR_LAND_TEST an invalid PR_LAND_NOW is ignored (no exit 10)"
  skip "without PR_LAND_TEST arm does not use PR_LAND_GH_PATH: the fake is not called, nothing armed"
fi
pl_gone() { run env PR_LAND_TEST=1 PR_LAND_GH_PATH="$tmp/nowhere" bash "$script" "$@"; }
resp 7 OPEN false $S1 main MERGEABLE "" "[]"; pl_gone arm $R 7 --sha $S1
check "arm with gh not found: exit 10 and a message, no state" '[ $rc -eq 10 ] && grep -q "gh not found" <<<"$err" && [ ! -e "$(sf $R 7)" ]' "rc=$rc err=[$err]"
mkstate $R 8 $S1 main $A1H armed; pl_gone sweep
check "sweep with gh not found: one stderr line, entry left armed, no notice" '[ "$(grep -c . <<<"$err")" = 1 ] && [ "$(sget "$(sf $R 8)" status)" = armed ] && [ "$(nlines)" = 0 ]' "rc=$rc err=[$err]"

# ---------- the whole suite: gh was only ever asked to view ----------
check "gh was called during the suite" '[ -s "$GH_ALL_LOG" ]'
check "recorded gh argv log contains only pr view calls" '[ "$(grep -vc "^pr view " "$GH_ALL_LOG")" = 0 ]' "$(grep -v '^pr view ' "$GH_ALL_LOG" | head -3)"
check "recorded gh argv log has no merge, ready, comment, review, close or api" '! grep -Eqw "merge|ready|comment|review|close|api" "$GH_ALL_LOG"'

# tripwire: every gh the script executed was the fake, and the fake recorded each one
check "tripwire: gh calls the script made (counted by the timeout shim) equal the calls the fake recorded" '[ "$(grep -c "^exec " "$SHIM_LOG")" = "$(wc -l <"$GH_ALL_LOG")" ] && [ "$(grep -c "^exec " "$SHIM_LOG")" -gt 0 ]' "shim=$(grep -c '^exec ' "$SHIM_LOG") fake=$(wc -l <"$GH_ALL_LOG")"
check "tripwire: no executed gh path was anything but the fake" '! grep "^exec " "$SHIM_LOG" | grep -F "/gh " | grep -qvF "$fakebin/gh "' "$(grep '^exec ' "$SHIM_LOG" | grep -vF "$fakebin/gh " | head -2)"

check "tripwire: no bare gh was ever run through the suite's PATH" '[ ! -s "$TRIP_LOG" ]' "$(cat "$TRIP_LOG" 2>/dev/null | head -3)"

echo; echo "$pass passed, $fail failed, $skipped skipped (script: $script)"
[ "$fail" -eq 0 ]
