#!/usr/bin/env bash
# PreToolUse gate: keep infrastructure details (private hostnames, IPs, emails,
# configured terms) out of commit messages and PR text on PUBLIC repositories.
# Applies to the main session AND subagents.
#
# Register on PreToolUse with matcher `Bash`. Not registered by this repo.
#
# Text comes from `git commit` messages and `gh pr create|edit|comment|review`
# title/body (including body files). The repo is the effective directory's
# `origin` (or gh --repo/-R); visibility comes from local config globs, a
# 7-day cache, or a 4s `gh repo view` lookup. Unknown visibility allows.
# Parsing and scanning live in _public-text-check.py.
#
# Config (data only, never sourced): ${CLAUDE_PUBLIC_TEXT_GATE_CONF:-~/.claude/public-text-gate.conf};
# see public-text-gate.conf.example. Without it only the built-in detectors run.
#
# Fails open everywhere: bad input, missing jq/python3, undeterminable state.
# Off switch: CLAUDE_PUBLIC_TEXT_GATE=off. PUBLIC_TEXT_GATE_NO_NETWORK=1 skips the lookup.
set -uo pipefail
[ "${CLAUDE_PUBLIC_TEXT_GATE:-on}" = "off" ] && exit 0
payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0
_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"

tool_name="$(jq -r '.tool_name // empty' <<<"$payload")"
command_str="$(jq -r '.tool_input.command // empty' <<<"$payload")"
cwd="$(jq -r '.cwd // empty' <<<"$payload")"
{ [ "$tool_name" = "Bash" ] || [ -z "$tool_name" ]; } || exit 0
[ -n "$command_str" ] || exit 0
# Cheap prefilter: neither `git` nor `gh` anywhere, nothing to judge.
case "$command_str" in *git*|*gh*) ;; *) exit 0 ;; esac
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

out="$(CMD="$command_str" CWD="$cwd" python3 -I "$_gate_dir/_public-text-check.py" 2>/dev/null)" || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
