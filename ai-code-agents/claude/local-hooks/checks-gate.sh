#!/usr/bin/env bash
# PreToolUse hook: before `git push` or `gh pr create`, the HEAD commit should
# have a passing check record (stamp) written by run-checks.sh (git-verify).
# Applies to the main session AND subagents. Register on PreToolUse, matcher `Bash`.
#
# Read-only: never runs checks, never changes a repository. No stamp needed
# when the repo has no checks, or every change since the base is documentation.
# Not pushed: --dry-run/-n, --delete/-d, tags-only, a ref that is not the
# current branch, `gh pr create --repo`.
# Unknown directory: when the directory a push or `gh pr create` runs in cannot
# be established (cd/pushd/-C with a variable or substitution, any --git-dir,
# --work-tree, GIT_DIR= or GIT_WORK_TREE= on a push, `cd -`, popd, a `bash -c`/
# `sh -c`/`eval` body doing so) the gate denies/warns ("could not tell which
# repository ... write the directory literally"); dry-run, delete (also `:ref`)
# and tags-only stay exempt. A variable resolves only from a standalone literal
# assignment certain to have run (never a prefix assignment or a conditional one).
# This gate has its own walker so the shared scanner stays unchanged; the variable
# handling is meant to move into the shared scanner in a follow-up.
# Known limits: bash -c/eval nesting over 3 levels (a line the walker cannot parse that holds a push is an unknown directory),
# git aliases, find -exec/ssh wrappers and lines over ~128 KB are not
# followed; a `cd` to a missing directory or after `false &&` is followed as if
# it ran (as before); word splitting under a changed IFS is not modelled.
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
