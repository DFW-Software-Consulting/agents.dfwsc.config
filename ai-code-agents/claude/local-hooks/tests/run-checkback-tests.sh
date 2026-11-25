#!/usr/bin/env bash
# CLI tests for bin/checkback ("tell me later": a durable reminder or a whitelisted read-only
# condition check, one notice). The seam is the command line: arguments, exit code, stdout,
# stderr, and the state files and notices.log it leaves. A fake `gh` is first on PATH, records
# every argv and prints a recognisable string on stdout and stderr; a fake notifier records what
# it is given. HOME and the XDG directories are throwaway. "Now" is CHECKBACK_NOW, the lock wait
# is CHECKBACK_LOCK_WAIT, TZ is fixed. No network, no real gh, no real config.
# Concurrency cases use marker-file handshakes, never fixed sleeps as synchronisation.
# The tool pins the environment of every condition and notifier call, so the fakes get their
# paths baked in at generation time instead of through environment variables. Test seams
# (CHECKBACK_NOW, _LOCK_WAIT, _COND_PATH, _COND_TIMEOUT, _NOTIFY_TIMEOUT) need CHECKBACK_TEST=1.
# Usage: local-hooks/tests/run-checkback-tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "$here/../.." && pwd)/bin/checkback"
[ -n "${CHECKBACK_SCRIPT:-}" ] && script="$CHECKBACK_SCRIPT"   # mutation proofs run a scratch copy
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config" TZ=UTC
mkdir -p "$HOME"
# hermetic: no credentials, no keyring or session bus, no host override reach anything the suite starts
unset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR GH_TOKEN GITHUB_TOKEN GH_HOST
sd="$XDG_STATE_HOME/checkback"
fx="$tmp/fx"; export FAKE_GH_DIR="$fx" GH_ALL_LOG="$tmp/gh-all.log"
export NOTIF_LOG="$tmp/notif.log" NOTIF_FAIL="$tmp/notif.fail"
M="$tmp/marker"   # no rejected input may ever create this
OUT_ALL="$tmp/all-output.log"; : >"$OUT_ALL"; NOTICES_ALL="$tmp/all-notices.log"; : >"$NOTICES_ALL"

fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat >"$fakebin/gh" <<GH
#!/usr/bin/env bash
d="$fx"; all="$GH_ALL_LOG"
GH
cat >>"$fakebin/gh" <<'GH'
printf '%s\n' "$*" >>"$d/calls.log"
printf '%s\n' "$*" >>"$all"
echo "SECRET_OUT_MARKER stdout"; echo "SECRET_OUT_MARKER stderr" >&2
if [ -e "$d/env-probe" ]; then env >"$d/env.log"; fi
if [ -e "$d/stdin-probe" ]; then
  [ -t 0 ] && t=1 || t=0; [ -p /dev/stdin ] && p=1 || p=0
  read -r -t 2 _x; echo "tty=$t pipe=$p read=$?" >"$d/stdin.log"
fi
if [ -e "$d/release-path" ]; then  # handshake: say we are in, then block until released (20 s hard bound)
  rel="$(cat "$d/release-path")"; : >"$d/entered"
  for _ in $(seq 1 400); do [ -e "$rel" ] && break; sleep 0.05; done
fi
if [ -e "$d/hang" ]; then for _ in $(seq 1 400); do sleep 0.05; done; fi
[ -e "$d/rc-$3" ] && exit "$(cat "$d/rc-$3")"
exit 0
GH
chmod +x "$fakebin/gh"
cat >"$tmp/notify.sh" <<N
#!/usr/bin/env bash
[ -e "$NOTIF_FAIL" ] && exit 1
if [ -e "$tmp/notify.hang" ]; then for _ in \$(seq 1 400); do sleep 0.05; done; exit 0; fi
env >"$tmp/notif.env"
printf '%s\n' "\$1" >>"$NOTIF_LOG"
printf '%s\n' "\$#" >>"$NOTIF_LOG.argc"
N
chmod +x "$tmp/notify.sh"
export PATH="$fakebin:$PATH"
fakepath="$fakebin:/usr/local/bin:/usr/bin:/bin"
export CHECKBACK_TEST=1 CHECKBACK_COND_PATH="$fakepath"
# Tripwire: the real gh must never run. Before every sweep, any gh condition in the state directory
# is only allowed when the sweep is made with CHECKBACK_TEST=1 and the fake PATH; else it is logged.
guard_sweep() {  # TEST_VALUE COND_PATH_VALUE
  local f
  for f in "$sd"/*.json; do
    [ -e "$f" ] || continue
    if jq -e '(.condition // [])[0] == "gh"' "$f" >/dev/null 2>&1; then
      { [ "$1" = 1 ] && [ "$2" = "$fakepath" ]; } || echo "gh condition swept outside the fake: $f" >>"$tmp/violations.log"
      echo "$f" >>"$tmp/gh-sweeps.log"
    fi
  done
  return 0
}

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

T0=2026-11-24T12:00:00Z
fresh() {
  [ -e "$sd/notices.log" ] && cat "$sd/notices.log" >>"$NOTICES_ALL"
  rm -rf "$sd" "$XDG_CONFIG_HOME" "$fx" "$NOTIF_LOG" "$NOTIF_LOG.argc" "$NOTIF_FAIL" "$M"; mkdir -p "$fx"
  export CHECKBACK_NOW=$T0 TZ=UTC; unset CHECKBACK_LOCK_WAIT CHECKBACK_COND_TIMEOUT CHECKBACK_NOTIFY_TIMEOUT
}
withnotif() { mkdir -p "$XDG_CONFIG_HOME/pr-land"; printf 'NOTIFY_CMD=%s\n' "$tmp/notify.sh" >"$XDG_CONFIG_HOME/pr-land/notify.conf"; }
run() { case " $* " in *" sweep "*) guard_sweep "${CHECKBACK_TEST:-}" "${CHECKBACK_COND_PATH:-}" ;; esac; out="$("$@" 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"; printf '%s\n%s\n' "$out" "$err" >>"$OUT_ALL"; }
cb() { run bash "$script" "$@"; }
sf() { echo "$sd/$1.json"; }
sget() { jq -r ".$2 | if . == null then \"\" else tostring end" "$(sf "$1")"; }
nlog() { cat "$sd/notices.log" 2>/dev/null; }
nlines() { nlog | wc -l; }
nstates() { ls "$sd"/*.json 2>/dev/null | wc -l; }
waitfor() { local _i; for _i in $(seq 1 200); do [ -e "$1" ] && return 0; sleep 0.05; done; return 1; }
# add_ok ARGS...: runs add, sets id
add_ok() { cb add "$@"; id="$(awk '{print $2}' <<<"$out")"; }
# mk ID [EXTRA_JSON]: a forged (or hand-made) state file with defaults, merged with EXTRA_JSON
mk() {
  local x="${2:-}"; [ -n "$x" ] || x='{}'; mkdir -p "$sd"
  jq -n --arg id "$1" --argjson x "$x" '{id:$id,text:"forged text",due_at:"2026-11-24T11:00:00Z",created_at:"2026-11-24T10:00:00Z",status:"armed",condition:null,every_min:5,max:12,attempts:0,pending_msg:""} + $x' >"$sd/$1.json"
}
gh_rc() { echo "$2" >"$fx/rc-$1"; }

# ---------- usage and environment ----------
fresh
cb; check "no arguments: usage, exit 10" '[ $rc -eq 10 ] && grep -qi usage <<<"$err"' "rc=$rc err=[$err]"
cb bogus; check "unknown command: usage, exit 10" '[ $rc -eq 10 ] && grep -qi usage <<<"$err"' "rc=$rc err=[$err]"
cb sweep extra; check "sweep with an argument: exit 10" '[ $rc -eq 10 ]' "rc=$rc"
cb list extra; check "list with an argument: exit 10" '[ $rc -eq 10 ]' "rc=$rc"
run env PATH="$tmp/empty" /bin/bash "$script" list; check "missing jq: exit 10" '[ $rc -eq 10 ]' "rc=$rc"
CHECKBACK_NOW=yesterday cb list; check "invalid CHECKBACK_NOW: exit 10" '[ $rc -eq 10 ]' "rc=$rc err=[$err]"
CHECKBACK_NOW=2026-13-45T99:00:00Z cb sweep; check "impossible CHECKBACK_NOW: exit 10" '[ $rc -eq 10 ]' "rc=$rc err=[$err]"

# ---------- add: arguments ----------
fresh
long300="$(head -c 300 </dev/zero | tr '\0' a)"; long301="${long300}a"
bad_args=(
  "--say hi"
  "--in 30m"
  "--at 15:30"
  "--in 30m --at 15:30 --say hi"
  "--in 0m --say hi" "--in 10081m --say hi" "--in 169h --say hi" "--in 0h --say hi" "--in 5x --say hi" "--in m --say hi"
  "--in -5m --say hi" "--in 5 --say hi" "--in 1.5h --say hi" "--in"
  "--at 24:00 --say hi" "--at 7:05 --say hi" "--at 12:60 --say hi" "--at noon --say hi" "--at 12:00:00 --say hi"
  "--in 5m --say" "--in 5m --say $long301" "--in 5m --say ''"
  "--in 5m --say hi --every 5m" "--in 5m --say hi --max 3"
  "--in 5m --say hi --until 'test -e /x' --every 0m" "--in 5m --say hi --until 'test -e /x' --every 61m"
  "--in 5m --say hi --until 'test -e /x' --every 5" "--in 5m --say hi --until 'test -e /x' --max 0"
  "--in 5m --say hi --until 'test -e /x' --max 289" "--in 5m --say hi --until 'test -e /x' --max x"
  "--in 5m --say hi --bogus" "--in 5m --say hi extra" "--in 5m --in 6m --say hi" "--in 5m --say a --say b"
)
for a in "${bad_args[@]}"; do
  # shellcheck disable=SC2294
  eval "cb add $a"
  check "add bad arguments exit 10 with usage, nothing written: [$a]" '[ $rc -eq 10 ] && grep -qi usage <<<"$err" && [ "$(nstates)" = 0 ]' "rc=$rc err=[$err]"
done
cb add --in 5m --say "$long300"; check "add: a 300-character text is accepted" '[ $rc -eq 0 ]' "rc=$rc err=[$err]"

# ---------- add: ok ----------
fresh
add_ok --in 30m --say 'check the thing'
check "add --in 30m: line, exit 0, id is letters and digits" '[ $rc -eq 0 ] && [[ "$out" =~ ^CHECKBACK\ [A-Za-z0-9]+\ armed\ due=2026-11-24T12:30:00Z$ ]]' "rc=$rc out=[$out] err=[$err]"
check "add: state file fields" '[ "$(sget "$id" id)" = "$id" ] && [ "$(sget "$id" text)" = "check the thing" ] && [ "$(sget "$id" due_at)" = 2026-11-24T12:30:00Z ] && [ "$(sget "$id" created_at)" = $T0 ] && [ "$(sget "$id" status)" = armed ] && [ "$(jq -c .condition "$(sf "$id")")" = null ] && [ "$(sget "$id" attempts)" = 0 ] && [ "$(sget "$id" pending_msg)" = "" ]' "$(cat "$(sf "$id")" 2>/dev/null)"
check "add: no temp files left behind" '[ -z "$(find "$sd" -name ".tmp*")" ]' "$(ls -a "$sd")"
add_ok --in 2h --say x; check "add --in 2h: due 14:00" '[ "$out" = "CHECKBACK $id armed due=2026-11-24T14:00:00Z" ]' "out=[$out]"
add_ok --in 10080m --say x; check "add --in 10080m accepted" '[ $rc -eq 0 ] && [ "$out" = "CHECKBACK $id armed due=2026-12-01T12:00:00Z" ]' "out=[$out]"
add_ok --in 168h --say x; check "add --in 168h accepted" '[ $rc -eq 0 ] && [ "$out" = "CHECKBACK $id armed due=2026-12-01T12:00:00Z" ]' "out=[$out]"
add_ok --in 1m --say x; check "add --in 1m accepted" '[ "$out" = "CHECKBACK $id armed due=2026-11-24T12:01:00Z" ]' "out=[$out]"
check "add: ids are distinct files" '[ "$(nstates)" = 5 ]'

# --at is local wall-clock time today, or tomorrow when it already passed
fresh; add_ok --at 15:30 --say x
check "add --at later than now: today" '[ "$out" = "CHECKBACK $id armed due=2026-11-24T15:30:00Z" ]' "out=[$out] err=[$err]"
add_ok --at 09:15 --say x
check "add --at earlier than now: tomorrow" '[ "$out" = "CHECKBACK $id armed due=2026-11-25T09:15:00Z" ]' "out=[$out] err=[$err]"
add_ok --at 12:00 --say x
check "add --at exactly now counts as passed: tomorrow" '[ "$out" = "CHECKBACK $id armed due=2026-11-25T12:00:00Z" ]' "out=[$out] err=[$err]"
TZ=America/Chicago add_ok --at 07:00 --say x
check "add --at uses the local zone (06:00 local now, 07:00 is today 13:00Z)" '[ "$out" = "CHECKBACK $id armed due=2026-11-24T13:00:00Z" ]' "out=[$out] err=[$err]"
TZ=America/Chicago add_ok --at 05:00 --say x
check "add --at in the local zone, already passed: tomorrow 11:00Z" '[ "$out" = "CHECKBACK $id armed due=2026-11-25T11:00:00Z" ]' "out=[$out] err=[$err]"

# text sanitising
fresh; add_ok --in 5m --say $'line1\nline2\x01\x7f tail; rm $(x) `y` <z>'
check "text with newline and control characters is sanitised to one line" '[ $rc -eq 0 ] && [ "$(sget "$id" text)" = "line1_line2__ tail_ rm _(x) _y_ _z_" ] && [ "$(wc -l <"$(sf "$id")")" -ge 1 ] && [ "$(jq -r .text "$(sf "$id")" | wc -l)" = 1 ] && [ "$(wc -l <<<"$out")" = 1 ]' "text=[$(sget "$id" text)] out=[$out]"
add_ok --in 5m --say "it's ok: a/b (c) d@e +1, f! g? #h =i - j._"
check "text keeps the allowed alphabet unchanged" '[ "$(sget "$id" text)" = "it'"'"'s ok: a/b (c) d@e +1, f! g? #h =i - j._" ]' "text=[$(sget "$id" text)]"

# ---------- sweep: no condition ----------
fresh; withnotif; add_ok --in 30m --say 'check the thing'
CHECKBACK_NOW=2026-11-24T12:29:59Z cb sweep
check "sweep before due: nothing happens" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(nlines)" = 0 ] && [ ! -e "$NOTIF_LOG" ] && [ "$(sget "$id" status)" = armed ]' "rc=$rc out=[$out] notices=[$(nlog)]"
CHECKBACK_NOW=2026-11-24T12:30:00Z cb sweep
check "sweep at the due time: one due notice, logged with a UTC timestamp, and delivered once" '[ $rc -eq 0 ] && [ "$(nlines)" = 1 ] && [ "$(nlog)" = "2026-11-24T12:30:00Z CHECKBACK $id due: check the thing" ] && [ "$(cat "$NOTIF_LOG")" = "CHECKBACK $id due: check the thing" ] && [ "$(cat "$NOTIF_LOG.argc")" = 1 ] && [ "$(sget "$id" status)" = done ]' "notices=[$(nlog)] notif=[$(cat "$NOTIF_LOG" 2>/dev/null)] state=$(sget "$id" status)"
CHECKBACK_NOW=2026-11-24T13:30:00Z cb sweep
check "second sweep sends nothing" '[ $rc -eq 0 ] && [ "$(nlines)" = 1 ] && [ "$(wc -l <"$NOTIF_LOG")" = 1 ]' "notices=[$(nlog)]"
fresh; add_ok --in 5m --say 'no notifier configured'
CHECKBACK_NOW=2026-11-24T12:10:00Z cb sweep
check "no notifier configured: the log line is the whole notice, state done, nothing pending" '[ "$(nlines)" = 1 ] && [ "$(sget "$id" status)" = done ] && [ -z "$(sget "$id" pending_msg)" ]' "notices=[$(nlog)]"
fresh; add_ok --in 5m --say x
for st in gave-up cancelled invalid "done"; do
  mk "t$st" "{\"status\":\"$st\"}"
done
CHECKBACK_NOW=2026-11-24T13:00:00Z cb sweep
check "terminal files with a past due time send nothing and keep their status" '[ "$(nlines)" = 1 ] && grep -q "$id due" <<<"$(nlog)" && [ "$(sget tdone status)" = done ] && [ "$(sget tgave-up status)" = gave-up ] && [ "$(sget tcancelled status)" = cancelled ] && [ "$(sget tinvalid status)" = invalid ]' "notices=[$(nlog)]"

# ---------- sweep: conditions ----------
flag="$tmp/flag"
fresh; withnotif; rm -f "$flag"; add_ok --in 10m --say 'waiting on flag' --until "test -e $flag" --every 10m --max 3
check "add with a condition stores words, every_min, max" '[ "$(jq -c .condition "$(sf "$id")")" = "[\"test\",\"-e\",\"$flag\"]" ] && [ "$(sget "$id" every_min)" = 10 ] && [ "$(sget "$id" max)" = 3 ] && [ "$(sget "$id" attempts)" = 0 ]' "$(cat "$(sf "$id")")"
CHECKBACK_NOW=2026-11-24T12:09:00Z cb sweep
check "condition: before due nothing is run or counted" '[ "$(sget "$id" attempts)" = 0 ]'
CHECKBACK_NOW=2026-11-24T12:10:00Z cb sweep
check "condition failing: attempts 1, rescheduled now+every, still armed, no notice" '[ "$(sget "$id" attempts)" = 1 ] && [ "$(sget "$id" due_at)" = 2026-11-24T12:20:00Z ] && [ "$(sget "$id" status)" = armed ] && [ "$(nlines)" = 0 ]' "$(cat "$(sf "$id")")"
CHECKBACK_NOW=2026-11-24T12:15:00Z cb sweep
check "condition: not rechecked before the rescheduled time" '[ "$(sget "$id" attempts)" = 1 ]'
CHECKBACK_NOW=2026-11-24T12:20:00Z cb sweep
check "condition failing again: attempts 2, due 12:30" '[ "$(sget "$id" attempts)" = 2 ] && [ "$(sget "$id" due_at)" = 2026-11-24T12:30:00Z ] && [ "$(sget "$id" status)" = armed ]'
CHECKBACK_NOW=2026-11-24T12:30:00Z cb sweep
check "gave-up at max: one gave-up notice, terminal" '[ "$(sget "$id" status)" = gave-up ] && [ "$(sget "$id" attempts)" = 3 ] && [ "$(nlines)" = 1 ] && grep -q "CHECKBACK $id gave-up: waiting on flag$" <<<"$(nlog)" && [ "$(wc -l <"$NOTIF_LOG")" = 1 ]' "$(cat "$(sf "$id")") notices=[$(nlog)]"
touch "$flag"; CHECKBACK_NOW=2026-11-24T14:00:00Z cb sweep
check "gave-up is final: later success sends nothing" '[ "$(nlines)" = 1 ] && [ "$(sget "$id" status)" = gave-up ]'
fresh; withnotif; add_ok --in 10m --say 'flag soon' --until "test -f $flag"
CHECKBACK_NOW=2026-11-24T12:10:00Z cb sweep
check "condition met: one met notice, done, attempts untouched" '[ "$(sget "$id" status)" = done ] && [ "$(sget "$id" attempts)" = 0 ] && [ "$(nlines)" = 1 ] && grep -q "CHECKBACK $id met: flag soon$" <<<"$(nlog)" && [ "$(cat "$NOTIF_LOG")" = "CHECKBACK $id met: flag soon" ]' "notices=[$(nlog)]"
rm -f "$flag"
fresh; add_ok --in 10m --say x --until "test -e $flag"
check "add with a condition defaults: every 5, max 12" '[ "$(sget "$id" every_min)" = 5 ] && [ "$(sget "$id" max)" = 12 ]'
CHECKBACK_NOW=2026-11-24T12:10:00Z cb sweep
check "default every is 5 minutes" '[ "$(sget "$id" due_at)" = 2026-11-24T12:15:00Z ]'

# each whitelisted shape is accepted, stored as words, and run with exactly that argv
fresh; withnotif
shapes=(
  "gh pr checks 6 -R octo/demo|pr checks 6 -R octo/demo"
  "gh pr checks 6 -R octo/demo --required|pr checks 6 -R octo/demo --required"
)
for s in "${shapes[@]}"; do
  cond="${s%%|*}"; export want="${s#*|}"; rm -f "$fx/calls.log"
  add_ok --in 5m --say "shape" --until "$cond"
  check "shape accepted at add: $cond" '[ $rc -eq 0 ] && [ -n "$id" ]' "rc=$rc err=[$err]"
  CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
  check "shape run with the exact argv: $cond" '[ "$(cat "$fx/calls.log")" = "$want" ] && [ "$(sget "$id" status)" = done ] && grep -q "CHECKBACK $id met: shape" <<<"$(nlog)"' "calls=[$(cat "$fx/calls.log" 2>/dev/null)] status=$(sget "$id" status)"
done
touch "$tmp/exists-file"; mkdir -p "$tmp/dir with space"; touch "$tmp/dir with space/f"
for cond in "test -f $tmp/exists-file" "test -e $tmp/exists-file" "test -e $tmp" "test -f '$tmp/dir with space/f'" "test -e \"$tmp/exists-file\""; do
  add_ok --in 5m --say "path" --until "$cond"
  check "path shape accepted at add: $cond" '[ $rc -eq 0 ] && [ -n "$id" ]' "rc=$rc err=[$err]"
  CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
  check "path shape met when the path exists: $cond" '[ "$(sget "$id" status)" = done ]' "status=$(sget "$id" status)"
done
add_ok --in 5m --say "path" --until "test -f $tmp/not-there"
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "test -f on a missing path: not met, attempt counted" '[ "$(sget "$id" status)" = armed ] && [ "$(sget "$id" attempts)" = 1 ]'
add_ok --in 5m --say "dir" --until "test -f $tmp"
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "test -f on a directory: not met" '[ "$(sget "$id" status)" = armed ]'
fresh; withnotif; rm -f "$fx/calls.log"; gh_rc 9 1; add_ok --in 5m --say g --until "gh pr checks 9 -R octo/demo"
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "gh exiting non-zero is not met: attempt counted, no notice" '[ "$(sget "$id" attempts)" = 1 ] && [ "$(sget "$id" status)" = armed ] && [ "$(nlines)" = 0 ]'
gh_rc 9 0; CHECKBACK_NOW=2026-11-24T12:10:00Z cb sweep
check "gh exiting 0 on a later sweep is met" '[ "$(sget "$id" status)" = done ] && grep -q "met: g$" <<<"$(nlog)"'

# ---------- rejected at add (nothing written, nothing executed) ----------
fresh
rejects=(
  "sh -c \"touch $M\""
  "bash -c 'touch $M'"
  "gh api repos/a/b"
  "gh pr view 5 -R a/b --jq .x"
  "gh pr view 5 -R a/b; touch $M"
  "gh pr view 5 -R a/b | touch $M"
  "gh pr view 5 -R a/b && touch $M"
  "gh pr view 5 -R a/b > $M"
  "gh pr view 5 -R a/b < $M"
  "test -f relative/path"
  "test -f /a/../b"
  "test -f /a/.."
  "test -d /tmp"
  "test -f /tmp/x -a -f /tmp/y"
  "test -f /tmp/*"
  "test -f /tmp/?x"
  "test -f /tmp/[a]"
  "test -f ~/x"
  "curl -fsS http://x"
  "touch $M"
  "echo \$(touch $M)"
  "test -f \"\$(touch $M)\""
  "test -f \`touch $M\`"
  "gh pr view 5 -R a/b --json 'state;touch'"
  "gh pr view 5 -R a/b --json state,"
  "gh pr view 5 -R a/b --json state,1x"
  "gh pr view 5 -R octo/demo"
  "gh pr view 5 -R octo/demo --json state,mergedAt"
  "gh run view 123 -R octo/demo"
  "gh run view 123 -R octo/demo --exit-status"
  "gh pr checks ５ -R octo/demo"
  "gh pr checks ٥ -R octo/demo"
  "gh pr checks 5 -R оcto/demo"
  "gh pr checks 5 -R octo/dеmo"
  "gh pr view 5 -R a/b --web"
  "gh pr view 5 -R a/b -q .x"
  "gh pr view 5 -R a/b --json state --json x"
  "gh pr view 5 --json state -R a/b"
  "gh pr view x5 -R a/b"
  "gh pr view 5 -R a"
  "gh pr view 5 -R a/b/c"
  "gh pr view 5 -R 'a b/c'"
  "gh pr view 5 -R=a/b"
  "gh pr view -R a/b 5"
  "gh pr view 5"
  "gh pr merge 5 -R a/b"
  "gh pr checks 5 -R a/b --watch"
  "gh pr checks 5 -R a/b --required --required"
  "gh run view 5 -R a/b --log"
  "gh run view 5 -R a/b --exit-status --json x"
  "gh run view 5 -R a/b --required"
  "gh pr view 5 -R a/b --exit-status"
  "gh issue view 5 -R a/b"
  "env gh pr view 5 -R a/b"
  "/usr/bin/gh pr view 5 -R a/b"
  "gh pr view 5 -R a/b {x}"
  "gh pr view 5 -R a/b \\\\x"
  "test -f '/tmp/unterminated"
  "test -f \"/tmp/unterminated"
  "test -f '/tmp/a;b'"
  "test -f '/tmp/a\$b'"
  ""
  "   "
)
for c in "${rejects[@]}"; do
  rm -f "$fx/calls.log"; cb add --in 5m --say x --until "$c"
  check "rejected at add: [$c]" '[ $rc -eq 2 ] && grep -q "condition not allowed" <<<"$out$err" && [ "$(nstates)" = 0 ] && [ ! -e "$M" ] && [ ! -e "$fx/calls.log" ]' "rc=$rc out=[$out] err=[$err] states=$(nstates)"
done
cb add --in 5m --say x --until $'test -f /tmp/x\ntouch '"$M"
check "rejected at add: a newline in the condition" '[ $rc -eq 2 ] && [ "$(nstates)" = 0 ] && [ ! -e "$M" ]' "rc=$rc"
cb add --in 5m --say x --until $'test -f /tmp/x\ttouch '"$M"
check "rejected at add: a tab in the condition" '[ $rc -eq 2 ] && [ "$(nstates)" = 0 ] && [ ! -e "$M" ]' "rc=$rc"
check "rejected adds left no state directory content" '[ -z "$(ls "$sd" 2>/dev/null | grep -v "^\.lock$")" ]' "$(ls -a "$sd" 2>/dev/null)"

# ---------- forged and damaged state files ----------
fresh; withnotif
mk forged1 "{\"condition\":[\"sh\",\"-c\",\"touch $M\"]}"
mk forged2 '{"condition":["gh","api","repos/a/b"]}'
mk forged3 '{"condition":["gh","pr","view","5","-R","octo/demo","--jq",".x"]}'
mk forged4 "{\"condition\":[\"test\",\"-f\",\"/a/../b\"]}"
mk forged5 "{\"condition\":[\"test\",\"-f\",\"/tmp/x\\nsh\"]}"
mk forged6 '{"condition":[]}'
mk forged7 '{"condition":["gh","pr","view","5","-R","octo/demo","; touch x"]}'
cp "$sd/forged1.json" "$tmp/forged1.before"
cb sweep
check "forged condition (sh -c): exit 0, nothing run, one stderr line, file kept, marked invalid, no notice" '[ $rc -eq 0 ] && [ ! -e "$M" ] && [ ! -e "$fx/calls.log" ] && [ "$(sget forged1 status)" = invalid ] && [ "$(nlines)" = 0 ] && [ ! -e "$NOTIF_LOG" ] && [ "$(jq -c "del(.status,.closed_at)" "$sd/forged1.json")" = "$(jq -c "del(.status)" "$tmp/forged1.before")" ]' "rc=$rc err=[$err] status=$(sget forged1 status)"
check "forged conditions (gh api, --jq, .., newline word, empty, metachar word): every one invalid, nothing run" '[ "$(sget forged2 status)" = invalid ] && [ "$(sget forged3 status)" = invalid ] && [ "$(sget forged4 status)" = invalid ] && [ "$(sget forged5 status)" = invalid ] && [ "$(sget forged6 status)" = invalid ] && [ "$(sget forged7 status)" = invalid ] && [ ! -e "$fx/calls.log" ]' "err=[$err]"
check "each invalid entry gave one stderr line" '[ "$(grep -c "forged[1-7]" <<<"$err")" = 7 ] && [ "$(grep -c . <<<"$err")" = 7 ]' "err=[$err]"
cb sweep; check "an invalid entry is not reported again or run" '[ $rc -eq 0 ] && [ "$(nlines)" = 0 ] && [ ! -e "$M" ] && [ -z "$err" ]' "err=[$err]"

fresh; withnotif
mk fm $'{"text":"a\\nrm -rf /\\u0001b `x` $(y)"}'
cb sweep
check "forged multi-line text yields a one-line sanitised notice" '[ "$(nlines)" = 1 ] && [ "$(nlog)" = "2026-11-24T12:00:00Z CHECKBACK fm due: a_rm -rf /_b _x_ _(y)" ] && [ "$(wc -l <"$NOTIF_LOG")" = 1 ] && [ "$(cat "$NOTIF_LOG")" = "CHECKBACK fm due: a_rm -rf /_b _x_ _(y)" ]' "notices=[$(nlog)]"
fresh; withnotif
mk fl "{\"text\":\"$(head -c 900 </dev/zero | tr '\0' b)\"}"
cb sweep
check "forged very long text: notice capped" '[ "$(nlines)" = 1 ] && [ "$(head -n1 "$NOTIF_LOG" | wc -c)" -le 501 ]' "len=$(head -n1 "$NOTIF_LOG" | wc -c)"

fresh; withnotif; mkdir -p "$sd"
printf '{not json' >"$sd/badjson.json"; echo '{"id":"missing"}' >"$sd/missing.json"
mk wrongtype1 '{"every_min":"5"}'; mk wrongtype2 '{"attempts":"0"}'; mk wrongtype3 '{"condition":"test -f /x"}'; mk wrongtype4 '{"status":"weird"}'
mk wrongtype5 '{"max":0}'; mk wrongtype6 '{"every_min":61}'; mk wrongtype7 '{"due_at":"tomorrow"}'; mk wrongtype8 '{"pending_msg":5}'; mk wrongtype9 '{"text":null}'
mk idmismatch '{"id":"other"}'; mk 'a..b' '{"id":"a..b"}'
mk good1
cp "$sd/badjson.json" "$tmp/bad.before"; cp "$sd/missing.json" "$tmp/missing.before"
cb sweep
check "damaged files: skipped with one stderr line each, never deleted or changed, the valid one still processed" '[ $rc -eq 0 ] && [ "$(cat "$sd/badjson.json")" = "{not json" ] && [ "$(cat "$sd/missing.json")" = "{\"id\":\"missing\"}" ] && [ "$(sget good1 status)" = done ] && [ "$(nlines)" = 1 ] && [ "$(grep -c "skipping" <<<"$err")" = 13 ] && [ "$(ls "$sd"/*.json | wc -l)" = 14 ] && [ "$(sget wrongtype1 status)" = armed ] && [ "$(sget wrongtype3 status)" = armed ]' "rc=$rc skipping-lines=$(grep -c skipping <<<"$err") err=[$err]"
cb list; check "list skips damaged files too (stderr), shows the valid one" '[ $rc -eq 0 ] && grep -q "^good1 " <<<"$out" && ! grep -q "wrongtype" <<<"$out"' "out=[$out]"

# ---------- notices: failure and recovery ----------
fresh; withnotif; : >"$NOTIF_FAIL"; add_ok --in 5m --say 'retry me'
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "notifier failing: notice logged, pending_msg stored, entry still terminal" '[ $rc -eq 0 ] && [ "$(sget "$id" status)" = done ] && [ "$(nlines)" = 1 ] && [ "$(sget "$id" pending_msg)" = "CHECKBACK $id due: retry me" ] && [ ! -e "$NOTIF_LOG" ]' "$(cat "$(sf "$id")")"
CHECKBACK_NOW=2026-11-24T12:06:00Z cb sweep
check "notifier still failing: still pending, no second log line" '[ -n "$(sget "$id" pending_msg)" ] && [ "$(nlines)" = 1 ]'
rm -f "$NOTIF_FAIL"; CHECKBACK_NOW=2026-11-24T12:07:00Z cb sweep
check "recovery: the next sweep delivers the pending notice once, clears it, does not log it again" '[ -z "$(sget "$id" pending_msg)" ] && [ "$(wc -l <"$NOTIF_LOG")" = 1 ] && [ "$(cat "$NOTIF_LOG")" = "CHECKBACK $id due: retry me" ] && [ "$(nlines)" = 1 ]' "notif=[$(cat "$NOTIF_LOG" 2>/dev/null)]"
CHECKBACK_NOW=2026-11-24T12:08:00Z cb sweep
check "after recovery nothing is delivered again" '[ "$(wc -l <"$NOTIF_LOG")" = 1 ]'
for badcmd in "/nonexistent/notifier" "relative/notify.sh" "$tmp/bin"; do
  fresh; mkdir -p "$XDG_CONFIG_HOME/pr-land"; printf 'NOTIFY_CMD=%s\n' "$badcmd" >"$XDG_CONFIG_HOME/pr-land/notify.conf"; add_ok --in 5m --say 'bad notifier'
  CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
  check "unusable notifier [$badcmd]: pending_msg stored, logged" '[ -n "$(sget "$id" pending_msg)" ] && [ "$(nlines)" = 1 ]' "$(cat "$(sf "$id")")"
done
fresh; echo '#!/usr/bin/env bash' >"$tmp/noexec.sh"; chmod -x "$tmp/noexec.sh"; mkdir -p "$XDG_CONFIG_HOME/pr-land"; printf 'NOTIFY_CMD=%s\n' "$tmp/noexec.sh" >"$XDG_CONFIG_HOME/pr-land/notify.conf"; add_ok --in 5m --say 'noexec'
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "non-executable notifier: pending_msg stored" '[ -n "$(sget "$id" pending_msg)" ]'
# the config is parsed, never sourced
fresh; mkdir -p "$XDG_CONFIG_HOME/pr-land"
printf 'touch %s\nNOTIFY_CMD=%s\n$(touch %s)\n' "$M" "$tmp/notify.sh" "$M" >"$XDG_CONFIG_HOME/pr-land/notify.conf"; add_ok --in 5m --say 'parsed'
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "notify.conf is parsed, not sourced: the marker is never created, the notifier ran" '[ ! -e "$M" ] && [ "$(cat "$NOTIF_LOG")" = "CHECKBACK $id due: parsed" ]'
fresh; mkdir -p "$XDG_CONFIG_HOME/pr-land"; printf 'NOTIFY_CMD=$(touch %s)\n' "$M" >"$XDG_CONFIG_HOME/pr-land/notify.conf"; add_ok --in 5m --say 'subst'
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "a substitution in NOTIFY_CMD is never run" '[ ! -e "$M" ] && [ -n "$(sget "$id" pending_msg)" ]'

# pending_msg read back from a state file is untrusted
fresh; withnotif; mk p1 '{"status":"done","pending_msg":"rm -rf / please"}'
cb sweep
check "forged pending_msg not starting with CHECKBACK: dropped, never delivered, cleared, one stderr line" '[ ! -e "$NOTIF_LOG" ] && [ -z "$(sget p1 pending_msg)" ] && [ "$(grep -c p1 <<<"$err")" = 1 ] && [ "$(nlines)" = 0 ]' "err=[$err]"
fresh; withnotif; mk p2 $'{"status":"done","pending_msg":"CHECKBACK p2 due: a\\nrm -rf /\\u0001tail;$(x)"}'
cb sweep
check "forged multi-line pending_msg is delivered as one sanitised line" '[ "$(wc -l <"$NOTIF_LOG")" = 1 ] && [ "$(cat "$NOTIF_LOG")" = "CHECKBACK p2 due: a_rm -rf /_tail__(x)" ] && [ -z "$(sget p2 pending_msg)" ]' "notif=[$(cat "$NOTIF_LOG" 2>/dev/null)]"
fresh; withnotif; mk p3 "{\"status\":\"done\",\"pending_msg\":\"CHECKBACK p3 due: $(head -c 800 </dev/zero | tr '\0' c)\"}"
cb sweep
check "forged long pending_msg is capped at 500 characters" '[ "$(head -n1 "$NOTIF_LOG" | tr -d "\n" | wc -c)" = 500 ]' "len=$(head -n1 "$NOTIF_LOG" 2>/dev/null | tr -d '\n' | wc -c)"
fresh; withnotif; mk p4 $'{"status":"done","pending_msg":"\\nCHECKBACK p4 due: leading newline"}'
cb sweep
check "a pending_msg that only starts with CHECKBACK after a newline is dropped" '[ ! -e "$NOTIF_LOG" ] && [ -z "$(sget p4 pending_msg)" ]' "notif=[$(cat "$NOTIF_LOG" 2>/dev/null)]"
fresh; withnotif; mk p5 '{"status":"done","pending_msg":"CHECKBACK p5 due: old","closed_at":"2026-10-01T00:00:00Z","due_at":"2026-10-01T00:00:00Z"}'
cb sweep
check "a stale terminal file (older than 14 days) is ignored: its pending notice is not retried, file kept" '[ ! -e "$NOTIF_LOG" ] && [ -e "$(sf p5)" ] && [ "$(sget p5 pending_msg)" = "CHECKBACK p5 due: old" ]'

# ---------- list and cancel ----------
fresh; withnotif
add_ok --in 30m --say 'first thing'; id1="$id"
add_ok --in 60m --say 'second thing' --until "test -e $tmp/never"; id2="$id"; export id2
mk oldterm '{"status":"done","closed_at":"2026-10-01T00:00:00Z","due_at":"2026-10-01T00:00:00Z","text":"ancient"}'
mk recentterm '{"status":"done","closed_at":"2026-11-20T00:00:00Z","due_at":"2026-11-20T00:00:00Z","text":"recent"}'
cb list
check "list: id, status, due, attempts and text per entry; old terminal files not shown" '[ $rc -eq 0 ] && grep -Eq "^$id1 +armed +2026-11-24T12:30:00Z +0 +first thing$" <<<"$out" && grep -Eq "^$id2 +armed +2026-11-24T13:00:00Z +0 +second thing$" <<<"$out" && grep -Eq "^recentterm +done .* recent$" <<<"$out" && ! grep -q ancient <<<"$out"' "out=[$out]"
check "list changes nothing and keeps the old terminal file" '[ -e "$(sf oldterm)" ] && [ "$(nlines)" = 0 ]'
cb cancel "$id1"
check "cancel: exit 0, status cancelled, no notice" '[ $rc -eq 0 ] && [ "$(sget "$id1" status)" = cancelled ] && [ "$(nlines)" = 0 ]' "rc=$rc out=[$out] err=[$err]"
CHECKBACK_NOW=2026-11-24T20:00:00Z cb sweep
check "the other entry was checked once and stays armed" '[ "$(sget "$id2" attempts)" = 1 ] && [ "$(sget "$id2" status)" = armed ]' "$(cat "$(sf "$id2")")"
check "after cancel and sweep: no due notice for the cancelled id" '! grep -q "$id1" <<<"$(nlog)"' "notices=[$(nlog)]"
cb cancel nosuchid; check "cancel unknown id: exit 1" '[ $rc -eq 1 ]' "rc=$rc"
cb cancel '../x'; check "cancel with a path-like id: exit 1, nothing touched" '[ $rc -eq 1 ] && [ ! -e "$sd/../x.json" ]' "rc=$rc"
cb cancel "$id1"; check "cancel of an already cancelled id: exit 1" '[ $rc -eq 1 ]' "rc=$rc"
cb cancel; check "cancel without an id: usage, exit 10" '[ $rc -eq 10 ]' "rc=$rc"
cb cancel a b; check "cancel with two ids: usage, exit 10" '[ $rc -eq 10 ]' "rc=$rc"
mk forgedc '{"status":"invalid"}'; cb cancel forgedc; check "cancel of an invalid entry: exit 1, file untouched" '[ $rc -eq 1 ] && [ "$(sget forgedc status)" = invalid ]' "rc=$rc"
printf '{nope' >"$sd/damaged.json"; cb cancel damaged; check "cancel of a damaged file: exit 1, bytes unchanged" '[ $rc -eq 1 ] && [ "$(cat "$sd/damaged.json")" = "{nope" ]' "rc=$rc"

# ---------- locking ----------
fresh; withnotif; rm -f "$tmp/never"
add_ok --in 5m --say 'lock test' --until "gh pr checks 77 -R octo/demo"
rel="$tmp/release1"; rm -f "$rel" "$fx/entered"; echo "$rel" >"$fx/release-path"
( CHECKBACK_NOW=2026-11-24T12:05:00Z bash "$script" sweep >"$tmp/first.out" 2>&1; echo $? >"$tmp/first.rc" ) &
bg=$!
waitfor "$fx/entered" || bad "first sweep reached gh" "marker never appeared"
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
check "second concurrent sweep is skipped at once, exit 0, saying so" '[ $rc -eq 0 ] && grep -qi skipped <<<"$out"' "rc=$rc out=[$out]"
: >"$rel"; wait "$bg"
check "first sweep finished normally while the second was skipped" '[ "$(cat "$tmp/first.rc")" = 0 ] && [ "$(cat "$tmp/first.out")" = "" ]' "rc=$(cat "$tmp/first.rc" 2>/dev/null) out=[$(cat "$tmp/first.out")]"
check "only the first sweep ran the condition, and the entry is done once" '[ "$(wc -l <"$fx/calls.log")" = 1 ] && [ "$(sget "$id" status)" = done ] && [ "$(nlines)" = 1 ]'

fresh; withnotif; mkdir -p "$sd"; mk held '{"text":"held"}'
rel="$tmp/release2"; rm -f "$rel" "$tmp/locked"
( flock 8; : >"$tmp/locked"; for _ in $(seq 1 400); do [ -e "$rel" ] && break; sleep 0.05; done ) 8>"$sd/.lock" & lk=$!
waitfor "$tmp/locked" || bad "holder took the lock" "marker never appeared"
CHECKBACK_LOCK_WAIT=1 cb add --in 5m --say 'blocked add'
check "add while the lock is held: waits, exits 1 with a message, writes nothing" '[ $rc -eq 1 ] && [ -n "$err" ] && [ "$(nstates)" = 1 ]' "rc=$rc err=[$err] states=$(nstates)"
CHECKBACK_LOCK_WAIT=1 cb cancel held
check "cancel while the lock is held: exit 1, state unchanged" '[ $rc -eq 1 ] && [ "$(sget held status)" = armed ]' "rc=$rc err=[$err]"
cb sweep; check "sweep while the lock is held: skipped at once, exit 0, nothing sent" '[ $rc -eq 0 ] && grep -qi skipped <<<"$out" && [ "$(nlines)" = 0 ] && [ "$(sget held status)" = armed ]' "rc=$rc out=[$out]"
check "all of that ran while the holder still held the lock" '[ ! -e "$rel" ]'
: >"$rel"; wait "$lk"
CHECKBACK_LOCK_WAIT=5 cb add --in 5m --say 'free now'; check "add succeeds once the lock is free" '[ $rc -eq 0 ] && [ "$(nstates)" = 2 ]' "rc=$rc err=[$err]"

# ---------- review round: removed shapes, forged shapes, pinned environment, seams, bounds, hangs ----------
fresh; withnotif
mk fv1 '{"condition":["gh","pr","view","5","-R","octo/demo"]}'
mk fv2 '{"condition":["gh","pr","view","5","-R","octo/demo","--json","state"]}'
mk fv3 '{"condition":["gh","run","view","5","-R","octo/demo"]}'
mk fv4 '{"condition":["gh","run","view","5","-R","octo/demo","--exit-status"]}'
cb sweep
check "removed shapes stored in a state file (pr view, run view): invalid at sweep, gh never run, no notice" '[ "$(sget fv1 status)" = invalid ] && [ "$(sget fv2 status)" = invalid ] && [ "$(sget fv3 status)" = invalid ] && [ "$(sget fv4 status)" = invalid ] && [ ! -e "$fx/calls.log" ] && [ "$(nlines)" = 0 ]' "err=[$err]"

# forged condition shapes and out-of-range numbers: nothing runs, no met, file kept
touch "$tmp/ctl"$'\001'"x"
fresh; withnotif
forged=(
  'c1|{"condition":[null]}'
  'c2|{"condition":[["a"]]}'
  'c3|{"condition":[1,2]}'
  'c4|{"condition":["test","-e","'"$tmp"'/ctl\u0001x"]}'
  'c5|{"condition":["gh","pr","checks","5","-R","octo/demo","--required","extra"]}'
  'c6|{"condition":["test","-f","/etc/passwd","extra"]}'
  'c7|{"condition":["test","-e","/etc/passwd"],"attempts":1e30,"max":1e30}'
  'c8|{"condition":["test","-e","/etc/passwd"],"max":289}'
  'c9|{"condition":["test","-e","/etc/passwd"],"attempts":100001}'
  'c10|{"condition":["test","-e","/etc/passwd"],"every_min":1e30}'
)
for f in "${forged[@]}"; do mk "${f%%|*}" "${f#*|}"; done
cb sweep
for f in "${forged[@]}"; do
  n="${f%%|*}"
  check "forged $n: kept, never met, no notice" '[ -e "$(sf "$n")" ] && [ "$(sget "$n" status)" != done ] && [ "$(nlines)" = 0 ]' "$(cat "$(sf "$n")")"
done
check "forged conditions: nothing ran" '[ ! -e "$fx/calls.log" ] && [ "$(nlines)" = 0 ]' "notices=[$(nlog)]"
check "forged c4 (control character in a word) is invalid, c5 and c6 (extra word) are invalid" '[ "$(sget c4 status)" = invalid ] && [ "$(sget c5 status)" = invalid ] && [ "$(sget c6 status)" = invalid ]'
check "forged c1,c2,c3,c7,c8,c9,c10 are damaged: skipped on stderr, status unchanged" '[ "$(grep -c "skipping invalid state file" <<<"$err")" = 7 ] && [ "$(sget c7 status)" = armed ] && [ "$(sget c8 status)" = armed ]' "err=[$err]"

# pinned environment of the condition and the notifier
fresh; withnotif; : >"$fx/env-probe"; add_ok --in 5m --say 'env' --until "gh pr checks 3 -R octo/demo"
# BASH_ENV is read by every non-interactive bash, including checkback itself; only the fake gh must not run it
printf 'case "$0" in */gh) touch %s ;; esac\n' "$M" >"$tmp/bashenv.sh"
export GH_HOST=evil.example GH_CONFIG_DIR=/tmp/x GH_REPO=a/b GH_TOKEN=tok GITHUB_TOKEN=tok2 GH_ENTERPRISE_TOKEN=tok3 GH_PAGER=less PAGER=less BROWSER=firefox BASH_ENV="$tmp/bashenv.sh" ENV="$tmp/bashenv.sh" GIT_DIR=/tmp/y GIT_WORK_TREE=/tmp/z XDG_CONFIG_HOME_KEEP="$XDG_CONFIG_HOME"
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep
unset GH_HOST GH_CONFIG_DIR GH_REPO GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_PAGER PAGER BROWSER BASH_ENV ENV GIT_DIR GIT_WORK_TREE XDG_CONFIG_HOME_KEEP
check "the condition ran (met) through the fake gh" '[ "$(sget "$id" status)" = done ] && [ -s "$fx/env.log" ]' "state=$(sget "$id" status)"
check "condition environment has none of GH_*, GITHUB_TOKEN, PAGER, BROWSER, BASH_ENV, ENV, GIT_*, XDG_CONFIG_HOME" '! grep -Eq "^(GH_|GITHUB_|GIT_|PAGER=|BROWSER=|BASH_ENV=|ENV=|XDG_CONFIG_HOME)" "$fx/env.log"' "$(cut -d= -f1 "$fx/env.log" | tr '\n' ' ')"
check "condition environment holds only the pass-list (plus what bash adds itself)" '[ -z "$(cut -d= -f1 "$fx/env.log" | grep -Evx "HOME|USER|LOGNAME|LANG|PATH|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|PWD|SHLVL|_|OLDPWD")" ] && grep -qx "LANG=C" "$fx/env.log" && grep -qx "HOME=$HOME" "$fx/env.log"' "$(cut -d= -f1 "$fx/env.log" | tr '\n' ' ')"
check "BASH_ENV script never ran" '[ ! -e "$M" ]'
check "notifier environment is pinned the same way" '[ -s "$tmp/notif.env" ] && [ -z "$(cut -d= -f1 "$tmp/notif.env" | grep -Evx "HOME|USER|LOGNAME|LANG|PATH|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|PWD|SHLVL|_|OLDPWD")" ]' "$(cut -d= -f1 "$tmp/notif.env" | tr '\n' ' ')"
# stdin is /dev/null
fresh; withnotif; : >"$fx/stdin-probe"; add_ok --in 5m --say 'stdin' --until "gh pr checks 3 -R octo/demo"
CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep < <(echo data; sleep 1)
check "condition stdin is not a terminal or a pipe and gives end of file at once" '[ "$(cat "$fx/stdin.log")" = "tty=0 pipe=0 read=1" ]' "$(cat "$fx/stdin.log" 2>/dev/null)"

# without CHECKBACK_TEST the seams are ignored
fresh; withnotif; mk far '{"due_at":"2029-01-01T00:00:00Z"}'
guard_sweep "" ""; env -u CHECKBACK_TEST CHECKBACK_NOW=2035-01-01T00:00:00Z bash "$script" sweep >/dev/null 2>&1
check "CHECKBACK_NOW without CHECKBACK_TEST is ignored: a not-yet-due entry does not fire" '[ "$(sget far status)" = armed ] && [ "$(nlines)" = 0 ]' "notices=[$(nlog)]"
env -u CHECKBACK_TEST CHECKBACK_NOW=garbage bash "$script" list >/dev/null 2>&1; rc=$?
check "an invalid CHECKBACK_NOW without CHECKBACK_TEST is ignored (no exit 10)" '[ $rc -eq 0 ]' "rc=$rc"
guard_sweep 1 "$fakepath"; CHECKBACK_NOW=2035-01-01T00:00:00Z bash "$script" sweep >/dev/null 2>&1
check "the same CHECKBACK_NOW with CHECKBACK_TEST=1 does fire it" '[ "$(sget far status)" = done ] && [ "$(nlines)" = 1 ]'
# the override is proved with a fake `test` binary, never with the real gh
mkdir -p "$tmp/fakepath"; rm -f "$tmp/faketest.calls"
printf '#!/usr/bin/%s\necho called >>"%s"\nexit 0\n' "env bash" "$tmp/faketest.calls" >"$tmp/fakepath/test"; chmod +x "$tmp/fakepath/test"
fresh; withnotif; mk ovr '{"due_at":"2020-01-01T00:00:00Z","condition":["test","-e","/nonexistent/checkback-never"]}'
guard_sweep "" ""; env -u CHECKBACK_TEST CHECKBACK_COND_PATH="$tmp/fakepath:/usr/bin:/bin" bash "$script" sweep >/dev/null 2>&1
check "CHECKBACK_COND_PATH without CHECKBACK_TEST is ignored: the fake test is not called, the real test says not met" '[ ! -e "$tmp/faketest.calls" ] && [ "$(sget ovr status)" = armed ] && [ "$(sget ovr attempts)" = 1 ] && [ "$(nlines)" = 0 ]' "calls=[$(cat "$tmp/faketest.calls" 2>/dev/null)] $(cat "$(sf ovr)")"
fresh; withnotif; mk ovr '{"due_at":"2020-01-01T00:00:00Z","condition":["test","-e","/nonexistent/checkback-never"]}'
guard_sweep 1 "$tmp/fakepath:/usr/bin:/bin"; CHECKBACK_COND_PATH="$tmp/fakepath:/usr/bin:/bin" bash "$script" sweep >/dev/null 2>&1
check "with CHECKBACK_TEST=1 the same override is honoured: the fake test ran and the entry is met" '[ -s "$tmp/faketest.calls" ] && [ "$(sget ovr status)" = done ] && [ "$(nlines)" = 1 ]' "calls=[$(cat "$tmp/faketest.calls" 2>/dev/null)] $(cat "$(sf ovr)")"

# hangs are killed by the timeouts
fresh; withnotif; : >"$fx/hang"; add_ok --in 5m --say 'hang' --until "gh pr checks 4 -R octo/demo"
SECONDS=0; CHECKBACK_COND_TIMEOUT=1 CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep; el=$SECONDS
check "a blocking condition is killed by the timeout: the sweep returns, one attempt counted, still armed" '[ $rc -eq 0 ] && [ "$el" -lt 15 ] && [ "$(sget "$id" attempts)" = 1 ] && [ "$(sget "$id" status)" = armed ] && [ "$(nlines)" = 0 ]' "rc=$rc elapsed=$el $(cat "$(sf "$id")")"
fresh; withnotif; : >"$tmp/notify.hang"; add_ok --in 5m --say 'nhang'
SECONDS=0; CHECKBACK_NOTIFY_TIMEOUT=1 CHECKBACK_NOW=2026-11-24T12:05:00Z cb sweep; el=$SECONDS
check "a blocking notifier is killed by the timeout: the sweep returns and leaves pending_msg" '[ $rc -eq 0 ] && [ "$el" -lt 15 ] && [ "$(sget "$id" status)" = done ] && [ "$(sget "$id" pending_msg)" = "CHECKBACK $id due: nhang" ] && [ "$(nlines)" = 1 ]' "rc=$rc elapsed=$el $(cat "$(sf "$id")")"
rm -f "$tmp/notify.hang"; CHECKBACK_NOW=2026-11-24T12:06:00Z cb sweep
check "after the hang ends the pending notice is delivered" '[ -z "$(sget "$id" pending_msg)" ] && [ "$(cat "$NOTIF_LOG")" = "CHECKBACK $id due: nhang" ]'

# bounded sweep: 250 due entries need two sweeps, each notified exactly once
fresh; withnotif; mkdir -p "$sd"
for i in $(seq 1 250); do
  printf '{"id":"bulk%s","text":"bulk %s","due_at":"2026-11-24T10:%02d:%02dZ","created_at":"2026-11-24T09:00:00Z","status":"armed","condition":null,"every_min":5,"max":12,"attempts":0,"pending_msg":""}\n' "$i" "$i" $((i / 60)) $((i % 60)) >"$sd/bulk$i.json"
done
cb sweep
check "250 due entries: the first sweep stops after 200 with one stderr line and exit 0" '[ $rc -eq 0 ] && [ "$(nlines)" = 200 ] && [ "$(grep -c "stopped early" <<<"$err")" = 1 ] && [ "$(grep -c . <<<"$err")" = 1 ]' "rc=$rc lines=$(nlines) err=[$err]"
cb sweep
check "the second sweep finishes the rest, quietly" '[ $rc -eq 0 ] && [ "$(nlines)" = 250 ] && [ -z "$err" ]' "rc=$rc lines=$(nlines) err=[$err]"
check "every one of the 250 was notified exactly once" '[ "$(nlog | awk "{print \$3}" | sort | uniq | wc -l)" = 250 ] && [ "$(wc -l <"$NOTIF_LOG")" = 250 ] && [ "$(sort "$NOTIF_LOG" | uniq -d | wc -l)" = 0 ]'
cb sweep; check "a third sweep sends nothing" '[ "$(nlines)" = 250 ]'

# ---------- the whole suite ----------
check "gh was called during the suite" '[ -s "$GH_ALL_LOG" ]'
check "recorded gh argv log contains only pr checks calls" '[ "$(grep -vc "^pr checks " "$GH_ALL_LOG")" = 0 ]' "$(grep -v '^pr checks ' "$GH_ALL_LOG" | head -3)"
check "recorded gh argv log has no write or api word" '! grep -Eqw "merge|ready|comment|review|close|api|edit|create" "$GH_ALL_LOG"'
[ -e "$sd/notices.log" ] && cat "$sd/notices.log" >>"$NOTICES_ALL"
check "the notices logs were non-empty" '[ -s "$NOTICES_ALL" ]'
check "condition output never appears in any notices.log" '! grep -q SECRET_OUT_MARKER "$NOTICES_ALL"'
check "condition output never appears in any stdout or stderr of the tool" '! grep -q SECRET_OUT_MARKER "$OUT_ALL"'
check "tripwire: no gh condition was ever swept outside the fake gh" '[ ! -s "$tmp/violations.log" ]' "$(cat "$tmp/violations.log" 2>/dev/null)"
check "tripwire: the guard saw gh conditions swept (so it is armed) and the fake gh recorded calls" '[ -s "$tmp/gh-sweeps.log" ] && [ -s "$GH_ALL_LOG" ]'
check "the marker file was never created by anything in the suite" '[ ! -e "$M" ]'

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
