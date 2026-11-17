#!/usr/bin/env bash
# PostToolUseFailure and PostToolUse hook (matcher mcp__brain__.*): when a call
# to a Brain database tool fails on a column, relation, enum or type error,
# adds a hint pointing at the private schema card and quoting the matching
# correction from it. Context only: it never blocks, denies or changes a call.
#
# This repo holds no schema detail. Corrections are read at run time from
# ${BRAIN_SCHEMA_CARD:-$HOME/.claude/local-docs/brain-schema-card.md}, a file
# that is NOT in this repo. No card, unknown input or any error means no
# output. Duplicate suppression: a short-lived marker per tool call id under
# ${XDG_CACHE_HOME:-$HOME/.cache}/claude-hooks, so a failure that raises both
# events produces one hint. Logic is in _brain-schema-hint.py. Exit 0 always.
set -uo pipefail
command -v python3 >/dev/null 2>&1 || exit 0
_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || exit 0
[ -r "$_dir/_brain-schema-hint.py" ] || exit 0
python3 -I "$_dir/_brain-schema-hint.py" 2>/dev/null
exit 0
