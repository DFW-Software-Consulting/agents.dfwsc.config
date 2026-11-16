#!/usr/bin/env bash
# PreToolUse hook: before `git push` or `gh pr create`, the HEAD commit should
# have a passing check record (stamp) written by run-checks.sh (git-verify).
# Applies to the main session AND subagents. Register on PreToolUse, matcher `Bash`.
#
# Read-only: never runs checks, never changes a repository. No stamp needed
# when the repo has no checks, or every change since the base is documentation.
# Not pushed: --dry-run/-n, --delete/-d, tags-only, a ref that is not the
# current branch, `gh pr create --repo`.
#
# Mode (data file, never sourced): ${CLAUDE_CHECKS_GATE_CONF:-~/.claude/checks-gate.conf}
#   MODE=warn|deny (default warn), DENY_AFTER=YYYY-MM-DD (deny from that date).
# warn prints a systemMessage plus additionalContext and allows; deny denies.
# Fails open on any problem. Escape hatch: CLAUDE_CHECKS_GATE=off.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
payload="$(cat)"
[ "${CLAUDE_CHECKS_GATE:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0
command_str="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)"
[ -n "$command_str" ] || exit 0
# Cheap prefilter: neither `git` nor `gh` as a word.
printf '%s' "$command_str" | grep -qwE 'git|gh' || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)"
CMD="$command_str" CWD="$cwd" GATE_HOME="$HOME" \
  python3 -B "$_gate_dir/_checks-gate-check.py" 2>/dev/null || exit 0
exit 0
