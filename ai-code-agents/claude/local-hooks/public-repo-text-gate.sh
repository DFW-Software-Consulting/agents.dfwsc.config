#!/usr/bin/env bash
# PreToolUse gate: keep infrastructure details (private hostnames, IPs, emails,
# configured terms) out of commit messages and PR text on PUBLIC repositories.
# Applies to the main session AND subagents.
#
# Register on PreToolUse with matcher `Bash`. Not registered by this repo.
#
# Text comes from `git commit` messages and `gh pr create|edit|comment|review`
# title/body (including body files). The repo is the effective directory's
# `origin` (or gh --repo/-R, whatever the directory); visibility comes from local
# config globs, a 7-day cache, or a 4s `gh repo view` lookup. Unknown visibility
# allows. When the directory cannot be established and no --repo is given, a text
# that trips a detector is denied (the repository could not be established; write
# the directory literally); a temporary (bare `mktemp -d`) directory is silent.
# Parsing and scanning live in _public-text-check.py.
#
# Config (data only, never sourced): ${CLAUDE_PUBLIC_TEXT_GATE_CONF:-~/.claude/public-text-gate.conf};
# see public-text-gate.conf.example. Without it only the built-in detectors run.
#
# Fails open everywhere: bad input, missing jq/python3, undeterminable state.
# Off switch: CLAUDE_PUBLIC_TEXT_GATE=off, or touch ~/.claude/public-text-gate.off
# (path overridable with CLAUDE_PUBLIC_TEXT_GATE_OFF_FILE); the off-file expires
# after 12 hours (see _gate-common.sh). PUBLIC_TEXT_GATE_NO_NETWORK=1 skips the lookup.
set -uo pipefail
[ "${CLAUDE_PUBLIC_TEXT_GATE:-on}" = "off" ] && exit 0
payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0
_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
# 12h off-file. If _gate-common.sh cannot be sourced, behave as gate ON.
off_note=""
if [ -n "$_gate_dir" ] && { HOME="${HOME-}"; source "$_gate_dir/_gate-common.sh" 2>/dev/null; }; then
  case "$(gate_off_file_state_for "${CLAUDE_PUBLIC_TEXT_GATE_OFF_FILE:-$HOME/.claude/public-text-gate.off}")" in
    fresh) exit 0 ;;
    stale) off_note="Note: the public-text-gate.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to switch the gate off." ;;
  esac
fi

tool_name="$(jq -r '.tool_name // empty' <<<"$payload")"
command_str="$(jq -r '.tool_input.command // empty' <<<"$payload")"
cwd="$(jq -r '.cwd // empty' <<<"$payload")"
{ [ "$tool_name" = "Bash" ] || [ -z "$tool_name" ]; } || exit 0
[ -n "$command_str" ] || exit 0
# Cheap prefilter: neither `git` nor `gh` anywhere, nothing to judge.
case "$command_str" in *git*|*gh*) ;; *) exit 0 ;; esac
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

out="$(GATE_OFF_NOTE="$off_note" CMD="$command_str" CWD="$cwd" python3 -I "$_gate_dir/_public-text-check.py" 2>/dev/null)" || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
