#!/usr/bin/env bash
# PreToolUse gate for SQL-executing MCP tools (execute_sql, apply_migration)
# that write to a database shared with other people. Makes the written rules
# structural: no touching rows someone else owns, look the project up before
# inserting, never insert a generated column, no schema changes by agents.
#
# Everything environment-specific comes from a local config file that is NOT in
# this repo (see shared-db-gate.conf.example). Without it, the gate is inactive.
# Disable with CLAUDE_SHARED_DB_GATE=off, or touch ~/.claude/shared-db-gate.off
# (path overridable with CLAUDE_SHARED_DB_GATE_OFF_FILE); the off-file expires
# after 12 hours (see _gate-common.sh). Applies to the main session and
# subagents alike. All SQL parsing lives in _sql-write-check.py; any
# infrastructure failure here fails open (exit 0, no output).
set -uo pipefail
[ "${CLAUDE_SHARED_DB_GATE:-}" = "off" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || exit 0
# 12h off-file. If _gate-common.sh cannot be sourced, behave as gate ON.
off_note=""
if { HOME="${HOME-}"; source "$_gate_dir/_gate-common.sh" 2>/dev/null; }; then
  case "$(gate_off_file_state_for "${CLAUDE_SHARED_DB_GATE_OFF_FILE:-$HOME/.claude/shared-db-gate.off}")" in
    fresh) exit 0 ;;
    stale) off_note="Note: the shared-db-gate.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to switch the gate off." ;;
  esac
fi
out="$(GATE_OFF_NOTE="$off_note" python3 -I "$_gate_dir/_sql-write-check.py" 2>/dev/null)" || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
