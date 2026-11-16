#!/usr/bin/env bash
# PreToolUse gate for SQL-executing MCP tools (execute_sql, apply_migration)
# that write to a database shared with other people. Makes the written rules
# structural: no touching rows someone else owns, look the project up before
# inserting, never insert a generated column, no schema changes by agents.
#
# Everything environment-specific comes from a local config file that is NOT in
# this repo (see shared-db-gate.conf.example). Without it, the gate is inactive.
# Disable with CLAUDE_SHARED_DB_GATE=off. Applies to the main session and
# subagents alike. All SQL parsing lives in _sql-write-check.py; any
# infrastructure failure here fails open (exit 0, no output).
set -uo pipefail
[ "${CLAUDE_SHARED_DB_GATE:-}" = "off" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || exit 0
out="$(python3 -I "$_gate_dir/_sql-write-check.py" 2>/dev/null)" || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
