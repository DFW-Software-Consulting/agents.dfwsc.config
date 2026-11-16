#!/usr/bin/env bash
# Shared by context-docs-start.sh, require-acceptance-criteria.sh and
# handback-gate.sh. Sourced, not executed.
#
# Agent types that are read-only or lookup agents and are never gated.
# Matching is exact on agent_type / subagent_type.
HANDBACK_EXEMPT_TYPES="Explore codebase-locator codebase-analyzer context-synthesis check web-fetch claude-code-guide Plan statusline-setup antipattern-sniffer fork"
# How many times a handback may be sent back before it goes through as is.
HANDBACK_SEND_BACK_CAP=2

# CLAUDE_ACCEPTANCE_GATE=off disables the acceptance gate entirely.
acceptance_gate_is_off() { [ "${CLAUDE_ACCEPTANCE_GATE:-on}" = "off" ]; }

# handback_is_exempt TYPE: success when TYPE is exempt. Empty is non-exempt.
handback_is_exempt() {
  local t="$1" e
  [ -n "$t" ] || return 1
  for e in $HANDBACK_EXEMPT_TYPES; do [ "$e" = "$t" ] && return 0; done
  return 1
}

# Longest report (characters, code blocks included) that goes through unsent
# back. Override with CLAUDE_HANDBACK_MAX_CHARS; non-numeric or zero = default.
HANDBACK_MAX_CHARS_DEFAULT=4000
handback_max_chars() {
  local v="${CLAUDE_HANDBACK_MAX_CHARS:-}"
  case "$v" in ''|*[!0-9]*) echo "$HANDBACK_MAX_CHARS_DEFAULT"; return ;; esac
  v=$((10#$v))
  [ "$v" -gt 0 ] || v="$HANDBACK_MAX_CHARS_DEFAULT"
  echo "$v"
}
