#!/usr/bin/env bash
# Shared by delegate-gate.sh, delegate-reminder.sh, require-agent-model.sh and
# worktree-gate.sh (which uses gate_off_file_state_for with its own off-file).
# Sourced, not executed. Decides whether the delegation gate is switched off.
#
# Gate is off when CLAUDE_DELEGATE_GATE=off, or when the off-file exists AND
# was modified less than GATE_OFF_TTL_SECONDS ago. A stale off-file is ignored
# (never deleted); `touch` it again to re-enable direct mode.
# The off-file path can be overridden with CLAUDE_DELEGATE_GATE_OFF_FILE.

GATE_OFF_TTL_SECONDS=$((12 * 60 * 60))
GATE_OFF_FILE="${CLAUDE_DELEGATE_GATE_OFF_FILE:-$HOME/.claude/delegate-gate.off}"

# Prints: none | fresh | stale, for the off-file at path $1.
gate_off_file_state_for() {
  local f="$1"
  # Only a regular file, or a symlink resolving to one, can be an off-file; it
  # is judged by the target's mtime (stat -L). A directory, a dangling link or
  # any other file type counts as no file.
  [ -f "$f" ] || { echo none; return; }
  local mtime now
  mtime="$(stat -L -c %Y "$f" 2>/dev/null)" || { echo none; return; }
  now="$(date +%s)"
  local age=$((now - mtime))
  # A future mtime is not trusted: treat as gate ON (stale).
  if [ "$age" -ge 0 ] && [ "$age" -lt "$GATE_OFF_TTL_SECONDS" ]; then echo fresh; else echo stale; fi
}

# Prints: none | fresh | stale (delegation gate's off-file).
gate_off_file_state() { gate_off_file_state_for "$GATE_OFF_FILE"; }

gate_is_off() {
  [ "${CLAUDE_DELEGATE_GATE:-on}" = "off" ] && return 0
  [ "$(gate_off_file_state)" = "fresh" ]
}

# Prints a one-line note only when an off-file exists but has expired.
gate_expired_note() {
  [ "$(gate_off_file_state)" = "stale" ] || return 0
  echo "Note: the delegate-gate.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to re-enable direct mode."
}
