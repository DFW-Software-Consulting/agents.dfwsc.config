#!/usr/bin/env bash
# Shared by delegate-gate.sh, delegate-reminder.sh and require-agent-model.sh.
# Sourced, not executed. Decides whether the delegation gate is switched off.
#
# Gate is off when CLAUDE_DELEGATE_GATE=off, or when the off-file exists AND
# was modified less than GATE_OFF_TTL_SECONDS ago. A stale off-file is ignored
# (never deleted); `touch` it again to re-enable direct mode.
# The off-file path can be overridden with CLAUDE_DELEGATE_GATE_OFF_FILE.

GATE_OFF_TTL_SECONDS=$((12 * 60 * 60))
GATE_OFF_FILE="${CLAUDE_DELEGATE_GATE_OFF_FILE:-$HOME/.claude/delegate-gate.off}"

# Prints: none | fresh | stale
gate_off_file_state() {
  [ -e "$GATE_OFF_FILE" ] || { echo none; return; }
  local mtime now
  mtime="$(stat -c %Y "$GATE_OFF_FILE" 2>/dev/null)" || { echo none; return; }
  now="$(date +%s)"
  local age=$((now - mtime))
  # A future mtime is not trusted: treat as gate ON (stale).
  if [ "$age" -ge 0 ] && [ "$age" -lt "$GATE_OFF_TTL_SECONDS" ]; then echo fresh; else echo stale; fi
}

gate_is_off() {
  [ "${CLAUDE_DELEGATE_GATE:-on}" = "off" ] && return 0
  [ "$(gate_off_file_state)" = "fresh" ]
}

# Prints a one-line note only when an off-file exists but has expired.
gate_expired_note() {
  [ "$(gate_off_file_state)" = "stale" ] || return 0
  echo "Note: the delegate-gate.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to re-enable direct mode."
}
