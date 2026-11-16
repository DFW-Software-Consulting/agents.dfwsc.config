#!/usr/bin/env bash
# PreToolUse gate: checks on `gh pr create`, `gh issue create` and `gh pr edit`
# (when it carries a body).
#   Always deny:  gh pr create from a head branch that is not pushed and in sync
#                 (judged from the local tracking ref, no network); a high-confidence
#                 secret in the title or body.
#   By mode:      missing sections from the repository's PR/issue template (or the
#                 SOP template for SOP_REPOS), unfilled template placeholders, a
#                 diff over the size cap without a Split plan or LOC-exception.
#                 PR_GATE_MODE=warn (default) allows with a message; deny denies;
#                 PR_GATE_DENY_AFTER=YYYY-MM-DD forces deny from that date.
# Applies to the main session AND subagents.
#
# Register on PreToolUse with matcher `Bash`.
#
# Skips commands whose body cannot be judged (--web, --fill, --fill-first,
# --template, unreadable body) and commands whose target repository (-R) is not
# the one in the effective directory. Commands and directories come from the
# shared walker (_cmd_dirs.py). With a directory that cannot be established,
# `gh pr create` is denied (write the directory literally) except in the skipped
# forms and --head owner:branch/-R; secrets in the title or body are judged from
# the text whatever the directory; template, placeholder and size rules are
# skipped. Only read-only git queries, inside a small time budget, no network.
# Fails open: bad input, missing jq/python3/git, an unparseable command, any error.
#
# Config (data only, never sourced): ${CLAUDE_GIT_GATES_CONF:-~/.claude/git-gates.conf};
# see git-gates.conf.example. Escape hatch: CLAUDE_PR_GATE=off.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

command_str="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)"
[ -n "$command_str" ] || exit 0
# Cheap prefilter: needs a `gh` word.
printf '%s' "$command_str" | grep -qw gh || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
[ "${CLAUDE_PR_GATE:-on}" = "off" ] && exit 0

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)"
CMD="$command_str" CWD="$cwd" python3 "$_gate_dir/_pr-gate-check.py" 2>/dev/null || true
exit 0
