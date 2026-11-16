#!/usr/bin/env bash
# Payload-driven tests for checks-gate.sh. Throwaway repos (each with a local
# bare origin), stamps made by the real run-checks.sh from .claude/git-checks
# files of plain shell commands, a temp HOME and a temp config file.
# Usage: local-hooks/tests/run-checks-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_CHECKS_GATE CHECKS_GATE_TODAY
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
export CLAUDE_CHECKS_GATE_CONF="$HOME/checks-gate.conf"
gate="bash $hooks/checks-gate.sh"
rc="$hooks/run-checks.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }
# classify PAYLOAD -> silent | warn | deny | other
classify() {
  local out; out="$(printf '%s' "$1" | $gate 2>&1)"
  if [ -z "$out" ]; then echo silent
  elif jq -e '.permissionDecision? == null and (.systemMessage|type=="string") and (.hookSpecificOutput|keys)==["additionalContext","hookEventName"] and .hookSpecificOutput.hookEventName=="PreToolUse" and (.hookSpecificOutput.additionalContext|type=="string")' <<<"$out" >/dev/null 2>&1; then echo warn
  elif jq -e '(.hookSpecificOutput|keys)==["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.hookEventName=="PreToolUse"' <<<"$out" >/dev/null 2>&1; then echo deny
  else echo "other:$out"; fi
}
check() {  # NAME EXPECT PAYLOAD
  local got; got="$(classify "$3")"
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "expected $2, got $got"; fi
}

T="$(mktemp -d "$HOME/t.XXXXXX")"
elsewhere="$T/elsewhere"; mkdir "$elsewhere"
bp() { jq -n --arg c "$1" --arg d "${2:-$elsewhere}" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
# mkrepo NAME CHECKS: repo on branch feat, bare origin (main), one code commit on feat, no upstream.
mkrepo() {
  local n="$1" d="$T/$1"
  git init -q --bare -b main "$T/$n.git"; git init -q -b main "$d"
  echo a > "$d/a.txt"
  if [ -n "${2:-}" ]; then mkdir -p "$d/.claude"; printf '%s\n' "$2" > "$d/.claude/git-checks"; fi
  git -C "$d" add -A; git -C "$d" commit -qm init
  git -C "$d" remote add origin "$T/$n.git"; git -C "$d" push -q origin main
  git -C "$d" fetch -q origin; git -C "$d" remote set-head origin main >/dev/null
  git -C "$d" checkout -q -b feat; echo b > "$d/code.txt"; git -C "$d" add -A; git -C "$d" commit -qm code
}
stamp() { bash "$rc" --dir "$1" >/dev/null 2>&1; }
stampfile() { echo "$1/.git/claude-checks/$(git -C "$1" rev-parse HEAD).json"; }
mode_warn() { printf 'MODE=warn\n' > "$CLAUDE_CHECKS_GATE_CONF"; }
mode_deny() { printf 'MODE=deny\n' > "$CLAUDE_CHECKS_GATE_CONF"; }
push() { bp "${1:-git push origin feat}" "${2:-$p}"; }

mkrepo r "true"; r="$T/r"; mkrepo p "true"; p="$T/p"
mkrepo nochk ""; mkrepo none "none"
mkrepo bad "true"; mkrepo stale "true"; mkrepo added "true"; mkrepo edited "true"; mkrepo wrongtree "true"
mkrepo failing "false"; mkrepo broken "true"
mkrepo docs "true"; mkrepo mixed "true"; mkrepo up "true"
snap() { for d in r p nochk none stale added edited wrongtree failing broken docs mixed up; do echo "$d $(git -C "$T/$d" rev-parse HEAD) $(git -C "$T/$d" status --porcelain | md5sum) $(git -C "$T/$d" ls-files -s | md5sum) $(ls "$T/$d/.git/claude-checks" 2>/dev/null | md5sum)"; done; }

# --- no checks / valid stamp ---
mode_deny
check "no checks detected allows silently" silent "$(push 'git push origin feat' "$T/nochk")"
check "checks opted out (none) allows silently" silent "$(push 'git push origin feat' "$T/none")"
check "no stamp denies in deny mode" deny "$(push)"
mode_warn
check "no stamp warns in warn mode" warn "$(push)"
rm -f "$CLAUDE_CHECKS_GATE_CONF"
check "no config file defaults to warn" warn "$(push)"
msg="$(printf '%s' "$(push)" | $gate | jq -r .systemMessage)"
case "$msg" in *"$(git -C "$p" rev-parse HEAD | cut -c1-10)"*run-checks.sh*true*) ok "warning names short sha, run-checks.sh and the detected commands";; *) bad "warning text" "$msg";; esac
printf 'MODE=bogus\n' > "$CLAUDE_CHECKS_GATE_CONF"
check "unknown MODE value behaves as warn" warn "$(push)"
mode_deny
stamp "$r"
check "valid stamp allows silently (deny mode)" silent "$(push 'git push origin feat' "$r")"
check "valid stamp allows gh pr create" silent "$(bp 'gh pr create --title x' "$r")"

# --- invalid stamps ---
stamp "$T/bad"; jq '.results[0].exit=1' "$(stampfile "$T/bad")" > "$T/x" && mv "$T/x" "$(stampfile "$T/bad")"
check "hand-edited stamp (exit changed) not valid" deny "$(push 'git push origin feat' "$T/bad")"
stamp "$T/edited"; jq '.detected=["true","true"]' "$(stampfile "$T/edited")" > "$T/x" && mv "$T/x" "$(stampfile "$T/edited")"
check "hand-edited stamp (detected changed) not valid" deny "$(push 'git push origin feat' "$T/edited")"
stamp "$T/failing"
check "failed stamp not valid" deny "$(push 'git push origin feat' "$T/failing")"
stamp "$T/stale"; echo c > "$T/stale/more.txt"; git -C "$T/stale" add -A; git -C "$T/stale" commit -qm more
check "stale stamp from previous commit not valid" deny "$(push 'git push origin feat' "$T/stale")"
stamp "$T/added"; echo 'echo extra' >> "$T/added/.claude/git-checks"
check "stamp missing a newly added check not valid" deny "$(push 'git push origin feat' "$T/added")"
git -C "$T/added" checkout -q -- .claude/git-checks
stamp "$T/wrongtree"; jq '.tree="0000000000000000000000000000000000000000"' "$(stampfile "$T/wrongtree")" > "$T/x" && mv "$T/x" "$(stampfile "$T/wrongtree")"
check "stamp with a wrong tree not valid" deny "$(push 'git push origin feat' "$T/wrongtree")"

# --- DENY_AFTER ---
printf 'MODE=warn\nDENY_AFTER=2026-12-01\n' > "$CLAUDE_CHECKS_GATE_CONF"
CHECKS_GATE_TODAY=2026-11-30 check "DENY_AFTER: day before warns" warn "$(push)"
CHECKS_GATE_TODAY=2026-12-01 check "DENY_AFTER: on the day denies" deny "$(push)"
CHECKS_GATE_TODAY=2026-12-02 check "DENY_AFTER: after denies" deny "$(push)"
printf 'MODE=warn\nDENY_AFTER=nonsense\n' > "$CLAUDE_CHECKS_GATE_CONF"
check "invalid DENY_AFTER ignored" warn "$(push)"
mode_deny

# --- docs-only ---
git -C "$T/docs" reset -q --hard HEAD~1; echo '# d' > "$T/docs/README.md"; mkdir "$T/docs/docs"; echo x > "$T/docs/docs/g.md"
git -C "$T/docs" add -A; git -C "$T/docs" commit -qm docs
check "docs-only change (merge base with default branch) allowed" silent "$(push 'git push origin feat' "$T/docs")"
git -C "$T/mixed" reset -q --hard HEAD~1; echo '# d' > "$T/mixed/README.md"; echo y > "$T/mixed/y.txt"
git -C "$T/mixed" add -A; git -C "$T/mixed" commit -qm mixed
check "mixed docs and code change not allowed" deny "$(push 'git push origin feat' "$T/mixed")"
# upstream present: base is the upstream
git -C "$T/up" push -q -u origin feat
echo '# more' > "$T/up/NOTES.md"; git -C "$T/up" add -A; git -C "$T/up" commit -qm notes
check "upstream present, docs-only since upstream allowed" silent "$(push 'git push' "$T/up")"
echo z > "$T/up/z.txt"; git -C "$T/up" add -A; git -C "$T/up" commit -qm z
check "upstream present, code since upstream not allowed" deny "$(push 'git push' "$T/up")"
# no base: no remote default branch
git init -q "$T/nobase"; mkdir "$T/nobase/.claude"; echo true > "$T/nobase/.claude/git-checks"; echo '# x' > "$T/nobase/README.md"
git -C "$T/nobase" add -A; git -C "$T/nobase" commit -qm i
check "no base found: docs-only not assumed" deny "$(push 'git push origin main' "$T/nobase")"

# --- which pushes count ---
git -C "$p" tag v9
check "push of another branch's ref allowed" silent "$(push 'git push origin other:other')"
check "push of another branch name allowed" silent "$(push 'git push origin other')"
check "push --dry-run ignored" silent "$(push 'git push --dry-run origin feat')"
check "push -n ignored" silent "$(push 'git push -n origin feat')"
check "push --delete ignored" silent "$(push 'git push origin --delete old')"
check "push -d ignored" silent "$(push 'git push -d origin old')"
check "tags-only push ignored" silent "$(push 'git push --tags')"
check "push of current branch by name judged" deny "$(push 'git push origin feat')"
check "push HEAD judged" deny "$(push 'git push origin HEAD')"
check "push HEAD:refs/heads/x judged" deny "$(push 'git push origin HEAD:refs/heads/x')"
check "bare push judged" deny "$(push 'git push')"
check "unrelated git command ignored" silent "$(push 'git status')"
check "non-git command ignored" silent "$(push 'ls')"
check "git word in quotes ignored" silent "$(push "echo 'git push origin feat'")"

# --- gh pr create ---
check "gh pr create from the repo directory judged" deny "$(bp 'gh pr create --title x' "$p")"
check "gh pr create with --repo skipped" silent "$(bp 'gh pr create --repo o/x --title x' "$p")"
check "gh pr create with -R skipped" silent "$(bp 'gh pr create -R o/x --title x' "$p")"
check "cd <repo> && gh pr create judged" deny "$(bp "cd $p && gh pr create --title x")"
check "gh pr list ignored" silent "$(bp 'gh pr list' "$p")"
check "gh pr create outside any repo allowed" silent "$(bp 'gh pr create --title x' "$elsewhere")"

# --- directory ---
check "git -C <repo> push judged from another cwd" deny "$(bp "git -C $p push origin feat")"
check "cd <repo> && git push judged" deny "$(bp "cd $p && git push origin feat")"
check "undeterminable cd allowed" silent "$(bp 'cd "$X" && git push origin feat')"
check "undeterminable -C allowed" silent "$(bp 'git -C "$X" push origin feat')"
check "missing directory allowed" silent "$(bp 'git push origin feat' "$T/nope")"
check "subagent payload judged too" deny "$(push | jq '.agent_id="a1"')"

# --- broken checks file, escape, config as data ---
git -C "$T/broken" reset -q --hard HEAD; printf 'none\ntrue\n' > "$T/broken/.claude/git-checks"; git -C "$T/broken" commit -qam brk
check "DetectionError allowed silently" silent "$(push 'git push origin feat' "$T/broken")"
CLAUDE_CHECKS_GATE=off check "CLAUDE_CHECKS_GATE=off allows" silent "$(push)"
touch_marker="$T/pwned"
printf 'MODE=deny\ntouch %s\n$(touch %s)\n`touch %s`\n' "$touch_marker" "$touch_marker" "$touch_marker" > "$CLAUDE_CHECKS_GATE_CONF"
check "config with shell syntax still parsed as data" deny "$(push)"
[ ! -e "$touch_marker" ] && ok "config shell syntax executed nothing" || bad "config shell syntax executed something"
printf 'MODE=deny; touch %s\n' "$touch_marker" > "$CLAUDE_CHECKS_GATE_CONF"
check "MODE value with shell syntax is not deny" warn "$(push)"
[ ! -e "$touch_marker" ] && ok "MODE value with shell syntax executed nothing" || bad "MODE value executed something"
mode_deny

# --- shapes and robustness ---
out="$(printf '%s' "$(push)" | $gate)"
jq -e '.hookSpecificOutput.permissionDecisionReason | test("run-checks.sh") and test("CLAUDE_CHECKS_GATE=off")' <<<"$out" >/dev/null && ok "deny reason names run-checks.sh and the escape hatch" || bad "deny reason" "$out"
silentp() { local out; out="$(printf '%s' "$2" | $gate 2>&1)"; [ -z "$out" ] && ok "$1" || bad "$1" "$out"; }
silentp "empty stdin silent" ''
silentp "malformed JSON silent" '{not json'
silentp "non-object JSON silent" '[1,2]'
silentp "empty object silent" '{}'
silentp "non-string command silent" '{"tool_input":{"command":5}}'
silentp "unterminated quote silent" "$(push "git push origin feat 'oops")"
nasty=$'git push origin feat; echo "q\\"x" \'s\'\n# nl'
check "deny with quotes and newlines in the command is valid JSON" deny "$(push "$nasty")"
mode_warn
check "warn with quotes and newlines in the command is valid JSON" warn "$(push "$nasty")"

# --- never modifies a repository ---
before="$(snap)"
for i in 1 2 3; do printf '%s' "$(push)" | $gate >/dev/null; printf '%s' "$(bp 'gh pr create' "$T/stale")" | $gate >/dev/null; done
[ "$before" = "$(snap)" ] && ok "HEAD, index, work tree and stamps of every repo unchanged" || bad "repo state changed"
[ -z "$(find "$hooks" -name __pycache__ -o -name '*.pyc' | head -1)" ] && ok "no bytecode written next to the hooks" || bad "bytecode written"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
