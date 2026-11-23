#!/usr/bin/env bash
# Completion gate for the MAIN session's own final reply. One script, two events:
#   UserPromptSubmit: records a baseline for the session (time, cwd, and the repo's
#     worktrees with their HEAD commits) in ${XDG_CACHE_HOME:-~/.cache}/claude-hooks/
#     completion-gate-<session>.base. One git call, no scan; negligible time.
#   Stop: if code changed this turn in the session's repo (its cwd checkout or any
#     linked worktree, including new commits and new worktrees), no passing check
#     record covers the changed tree (_checks_stamp.py stamps, docs-only changes and
#     repos without checks exempt, like checks-gate.sh), and the final reply has no
#     verification statement, it blocks ONCE asking for one. See _completion-gate-check.py.
# Accepted statements (a line starting with, case-insensitive, markdown marks and
# bullets ignored, then ':' or a dash): Verified, Not verified, Unverified, Not yet
# verified, Blocked, In progress. An honest "not verified" or "still running" passes:
# the gate stops silent completion claims, it never forces checks to run.
# Never blocks twice for a turn (stop_hook_active). Main session only: a payload with
# agent_id, or event SubagentStop, is ignored. Headless sessions (entrypoint sdk-cli or
# sdk-ts) are exempt like the reply cap. Fails open on any error, timeout (hard budget
# in the helper), non-git cwd, or missing or corrupt baseline.
# Off switch: CLAUDE_COMPLETION_GATE=off, or a fresh (under 12 hours old) regular file
# ~/.claude/completion-gate.off (CLAUDE_COMPLETION_GATE_OFF_FILE overrides the path).
# Mode (data file, never sourced): ${CLAUDE_COMPLETION_GATE_CONF:-~/.claude/completion-gate.conf}
#   MODE=deny (default, block once) | warn (a notice, never blocks).
# Register on UserPromptSubmit and Stop.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
payload="$(cat 2>/dev/null)" || exit 0
[ "${CLAUDE_COMPLETION_GATE:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || exit 0
source "$_dir/_gate-common.sh" 2>/dev/null || exit 0
[ "$(gate_off_file_state_for "${CLAUDE_COMPLETION_GATE_OFF_FILE:-$HOME/.claude/completion-gate.off}")" = "fresh" ] && exit 0

# One jq call: event, session id, cwd, agent id, stop_hook_active (one per line).
{ IFS= read -r event; IFS= read -r sid; IFS= read -r cwd; IFS= read -r agent; IFS= read -r active; } < <(
  jq -r 'if type == "object" then
    [(.hook_event_name // "" | strings), (.session_id // "" | strings), (.cwd // "" | strings),
     (.agent_id // "" | strings), (.stop_hook_active // false | tostring)] | .[]
  else empty end' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$event" ] && [ -n "$sid" ] && [ -n "$cwd" ] || exit 0
[ -z "$agent" ] || exit 0

base="${XDG_CACHE_HOME:-}"
if [ -z "$base" ]; then [ -n "${HOME:-}" ] || exit 0; base="$HOME/.cache"; fi
bdir="$base/claude-hooks"
key="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')"
bfile="$bdir/completion-gate-${key:0:100}.base"

case "$event" in
  UserPromptSubmit)
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-cli|sdk-ts) exit 0 ;; esac
    command -v git >/dev/null 2>&1 || exit 0
    wl="$(git -C "$cwd" worktree list --porcelain 2>/dev/null)" || exit 0
    [ -n "$wl" ] || exit 0
    mkdir -p "$bdir" 2>/dev/null || exit 0
    tmp="$bfile.$$"
    { printf 'ts=%s\ncwd=%s\n---\n%s\n' "$(date +%s.%N)" "$cwd" "$wl" >"$tmp" && mv -f "$tmp" "$bfile"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
    # Old baselines of finished sessions: remove those untouched for a week.
    find "$bdir" -maxdepth 1 -name 'completion-gate-*.base' -mtime +7 -delete 2>/dev/null
    exit 0 ;;
  Stop)
    command -v python3 >/dev/null 2>&1 || exit 0
    command -v git >/dev/null 2>&1 || exit 0
    conf="${CLAUDE_COMPLETION_GATE_CONF:-$HOME/.claude/completion-gate.conf}"
    mode=deny
    if [ -f "$conf" ]; then
      m="$(sed -n -E 's/^[[:space:]]*MODE[[:space:]]*=[[:space:]]*["'"'"']?([A-Za-z]+).*/\1/p' "$conf" 2>/dev/null | head -n 1 | tr 'A-Z' 'a-z')"
      [ "$m" = "warn" ] && mode=warn
    fi
    printf '%s' "$payload" | COMPLETION_GATE_BASE="$bfile" COMPLETION_GATE_MODE="$mode" COMPLETION_GATE_ACTIVE="$active" \
      python3 -B "$_dir/_completion-gate-check.py" 2>/dev/null || true
    exit 0 ;;
esac
exit 0
