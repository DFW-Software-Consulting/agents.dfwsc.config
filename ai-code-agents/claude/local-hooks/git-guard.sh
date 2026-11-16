#!/usr/bin/env bash
# PreToolUse gate: three hard git rules from the git-workflow skill.
#   1. No bypassing repository hooks (--no-verify, commit -n, HUSKY=0 /
#      SKIP= on commit or push, -c core.hooksPath= on commit or push).
#   2. No force pushes (--force, -f, --force-with-lease, --force-if-includes,
#      "+" refspecs; the list lives in FORCE_FLAGS in _git-guard-check.py).
#   3. No pushes to the default branch (explicit destination, bare push while
#      on it, --all, --mirror).
# A lease-only force push (--force-with-lease / --force-if-includes) is denied
# without a valid check stamp for HEAD and otherwise answered with "ask".
# Applies to the main session AND subagents.
#
# Register on PreToolUse with matcher `Bash`.
#
# Judged per git command by the quote-aware scanner (_git-cmd-scan.py), in the
# directory the command runs in (payload cwd, literal `cd`, `git -C`). Runs
# only read-only git queries. Fails open: bad input, missing jq/python3, an
# unparseable command, an undeterminable directory.
# Escape hatch: CLAUDE_GIT_GUARD=off, or touch ~/.claude/git-guard.off (path
# overridable with CLAUDE_GIT_GUARD_OFF_FILE); the off-file expires after 12
# hours (see _gate-common.sh). If _gate-common.sh is missing the guard stays ON.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

command_str="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)"
[ -n "$command_str" ] || exit 0
# Cheap prefilter: no `git` word, nothing to judge.
printf '%s' "$command_str" | grep -qw git || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
GG_OFF_FILE="${CLAUDE_GIT_GUARD_OFF_FILE:-$HOME/.claude/git-guard.off}"
if source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  gg_off_state() { gate_off_file_state_for "$GG_OFF_FILE"; }
else
  # Shared file unavailable: behave as guard ON.
  gg_off_state() { echo none; }
fi
[ "${CLAUDE_GIT_GUARD:-on}" = "off" ] && exit 0
off_state="$(gg_off_state)"
[ "$off_state" = "fresh" ] && exit 0

cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)"
hit="$(CMD="$command_str" CWD="$cwd" GATE_HOME="$HOME" \
  python3 "$_gate_dir/_git-guard-check.py" 2>/dev/null)" || exit 0
[ -n "$hit" ] || exit 0
rule="${hit%%$'\t'*}"
why="${hit#*$'\t'}"

if [ "$rule" = "lease-ask" ]; then
  jq -n --arg r "git-guard (force-with-lease): $why" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

note=""
[ "$off_state" = "stale" ] && note="Note: the git-guard.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to re-enable."
jq -n --arg r "git-guard ($rule): $why If JC explicitly asked for this exact action, he can run: touch ~/.claude/git-guard.off (valid 12 hours) or launch with CLAUDE_GIT_GUARD=off." --arg n "$note" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ($r + (if $n != "" then " " + $n else "" end))
  }
}'
exit 0
