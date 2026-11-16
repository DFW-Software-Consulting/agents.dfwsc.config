#!/usr/bin/env bash
# SessionStart / SubagentStart hook. Injects docs/context/INDEX.md when the repo
# at cwd has opted in, and on SubagentStart adds standing instructions for
# non-exempt agent types (read context docs, update them, acceptance check).
# Fails open: any error, missing tool or bad input means no output, exit 0.
set -uo pipefail
payload="$(cat 2>/dev/null)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if ! source "$_dir/_handback-common.sh" 2>/dev/null; then
  HANDBACK_EXEMPT_TYPES="Explore codebase-locator codebase-analyzer context-synthesis check web-fetch claude-code-guide Plan statusline-setup antipattern-sniffer fork"
  acceptance_gate_is_off() { [ "${CLAUDE_ACCEPTANCE_GATE:-on}" = "off" ]; }
  acceptance_gate_expired_note() { :; }
  handback_is_exempt() {
    local t="$1" e; [ -n "$t" ] || return 1
    for e in $HANDBACK_EXEMPT_TYPES; do [ "$e" = "$t" ] && return 0; done; return 1
  }
fi

event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null)" || exit 0
case "$event" in SessionStart|SubagentStart) ;; *) exit 0 ;; esac
cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)" || exit 0
agent_type="$(jq -r '.agent_type // empty' <<<"$payload" 2>/dev/null)" || exit 0

ctx=""
if [ -n "$cwd" ] && [ -d "$cwd" ] && command -v git >/dev/null 2>&1; then
  root="$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || root=""
  if [ -n "$root" ] && [ -f "$root/docs/context/INDEX.md" ]; then
    idx="$(cat "$root/docs/context/INDEX.md" 2>/dev/null)" || idx=""
    if [ -n "$idx" ]; then
      note=""
      if [ "${#idx}" -gt 3000 ]; then idx="${idx:0:3000}"; note=$'\n[INDEX.md truncated at 3000 characters; read docs/context/INDEX.md for the rest]'; fi
      ctx="This repo keeps context docs in docs/context/. Read the docs relevant to your task before starting, and check docs/context/errors.md before proposing a fix. Index:"$'\n\n'"$idx$note"
    fi
  fi
fi

if [ "$event" = "SubagentStart" ] && ! handback_is_exempt "$agent_type"; then
  add="Context docs: if the repo you work in has docs/context/INDEX.md, read it and the docs it marks relevant first. Before handing back, update those docs for what you changed. End your report with a line 'Context docs: updated <files>' or 'Context docs: no change needed, <reason>' or 'Context docs: none in this repo'."
  if ! acceptance_gate_is_off; then
    add="$add"$'\n\n'"Acceptance: before handing back, check every acceptance criterion from your brief against what you actually did, run the checks, and fix what fails. Include a section headed 'Acceptance check' with one line per criterion: '<criterion> : met | not met : <evidence>'."
  fi
  if [ -n "$ctx" ]; then ctx="$ctx"$'\n\n'"$add"; else ctx="$add"; fi
fi

[ -n "$ctx" ] || exit 0
jq -n --arg e "$event" --arg c "$ctx" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}' 2>/dev/null
exit 0
