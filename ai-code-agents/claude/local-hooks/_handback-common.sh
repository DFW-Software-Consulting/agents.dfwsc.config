#!/usr/bin/env bash
# Shared by context-docs-start.sh, require-acceptance-criteria.sh and
# handback-gate.sh. Sourced, not executed.
#
# Agent types that are read-only or lookup agents and are never gated.
# Matching is exact on agent_type / subagent_type.
HANDBACK_EXEMPT_TYPES="Explore codebase-locator codebase-analyzer context-synthesis check web-fetch claude-code-guide Plan statusline-setup antipattern-sniffer fork"
# How many times a handback may be sent back before it goes through as is.
HANDBACK_SEND_BACK_CAP=2

# The acceptance gate is off when CLAUDE_ACCEPTANCE_GATE=off, or when the
# off-file (~/.claude/acceptance-gate.off, path overridable with
# CLAUDE_ACCEPTANCE_GATE_OFF_FILE) was modified less than 12 hours ago, using
# gate_off_file_state_for from _gate-common.sh. A stale or future-dated file is
# ignored. If _gate-common.sh cannot be sourced the file is ignored (gate ON).
_HANDBACK_COMMON_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"

# Prints: none | fresh | stale.
acceptance_gate_off_state() {
  local HOME="${HOME-}"
  local f="${CLAUDE_ACCEPTANCE_GATE_OFF_FILE:-$HOME/.claude/acceptance-gate.off}"
  if ! declare -F gate_off_file_state_for >/dev/null 2>&1; then
    [ -n "$_HANDBACK_COMMON_DIR" ] || { echo none; return; }
    source "$_HANDBACK_COMMON_DIR/_gate-common.sh" 2>/dev/null || { echo none; return; }
  fi
  gate_off_file_state_for "$f"
}

acceptance_gate_is_off() {
  [ "${CLAUDE_ACCEPTANCE_GATE:-on}" = "off" ] && return 0
  [ "$(acceptance_gate_off_state)" = "fresh" ]
}

# Prints a one-line note only when an off-file exists but has expired.
acceptance_gate_expired_note() {
  [ "${CLAUDE_ACCEPTANCE_GATE:-on}" = "off" ] && return 0
  [ "$(acceptance_gate_off_state)" = "stale" ] || return 0
  echo "Note: the acceptance-gate.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to switch the acceptance gate off."
}

# handback_is_exempt TYPE: success when TYPE is exempt. Empty is non-exempt.
handback_is_exempt() {
  local t="$1" e
  [ -n "$t" ] || return 1
  for e in $HANDBACK_EXEMPT_TYPES; do [ "$e" = "$t" ] && return 0; done
  return 1
}

# Longest report (characters, code blocks included) that goes through unsent
# back. Override with CLAUDE_HANDBACK_MAX_CHARS: digits only, read as decimal
# (so 08 and 09 are 8 and 9, not octal); non-numeric or zero = default.
HANDBACK_MAX_CHARS_DEFAULT=4000
handback_max_chars() {
  local v="${CLAUDE_HANDBACK_MAX_CHARS:-}"
  case "$v" in ''|*[!0-9]*) echo "$HANDBACK_MAX_CHARS_DEFAULT"; return ;; esac
  v=$((10#$v))
  [ "$v" -gt 0 ] || v="$HANDBACK_MAX_CHARS_DEFAULT"
  echo "$v"
}
