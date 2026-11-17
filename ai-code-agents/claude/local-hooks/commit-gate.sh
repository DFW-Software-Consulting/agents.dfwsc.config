#!/usr/bin/env bash
# PreToolUse gate: pre-commit checks for `git commit` (not --dry-run).
#   Deny:  secret files being committed (.env, *.pem, *.key, id_rsa*, ...),
#          conflict markers in staged lines, high-confidence secrets in staged
#          content or in the commit message.
#   Warn:  commit subject format, only where the repo already follows
#          type(scope): description (commitlint config or conventional history).
# Applies to the main session AND subagents.
#
# Register on PreToolUse with matcher `Bash`.
#
# Reads the command with the shared walker (_cmd_dirs.py), in the directory it
# runs in (payload cwd, `cd`, `pushd`, `git -C`, `env -C`, plain variable
# assignments, GIT_DIR=, `bash -c`/`eval` bodies). A commit whose directory cannot
# be established is denied (write the directory literally); a bare `mktemp -d`
# directory is allowed; the message secret scan runs whatever the directory.
# Without _cmd_dirs.py the previous literal-directory scan runs.
# Only read-only git queries, inside a small time budget. Fails open: bad input,
# missing jq/python3/git, an unparseable command, an internal error.
#
# Config (data only, never sourced): ${CLAUDE_GIT_GATES_CONF:-~/.claude/git-gates.conf};
# ALLOW_PATHS exempts files from the file and content rules. See git-gates.conf.example.
# Escape hatch, shared with git-guard: CLAUDE_GIT_GUARD=off, or touch
# ~/.claude/git-guard.off (path overridable with CLAUDE_GIT_GUARD_OFF_FILE; expires
# after 12 hours). If _gate-common.sh is missing the gate stays ON.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

command_str="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)"
[ -n "$command_str" ] || exit 0
# Cheap prefilter: needs both a `git` word and the word commit.
printf '%s' "$command_str" | grep -qw git || exit 0
printf '%s' "$command_str" | grep -qw commit || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
CG_OFF_FILE="${CLAUDE_GIT_GUARD_OFF_FILE:-$HOME/.claude/git-guard.off}"
if source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  cg_off_state() { gate_off_file_state_for "$CG_OFF_FILE"; }
else
  cg_off_state() { echo none; }
fi
[ "${CLAUDE_GIT_GUARD:-on}" = "off" ] && exit 0
off_state="$(cg_off_state)"
[ "$off_state" = "fresh" ] && exit 0

note=""
[ "$off_state" = "stale" ] && note="Note: the git-guard.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to re-enable."
cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)"
CMD="$command_str" CWD="$cwd" NOTE="$note" \
  python3 "$_gate_dir/_commit-gate-check.py" 2>/dev/null || true
exit 0
