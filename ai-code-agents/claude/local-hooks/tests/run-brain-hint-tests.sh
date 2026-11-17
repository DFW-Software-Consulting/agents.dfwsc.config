#!/usr/bin/env bash
# Payload-driven tests for brain-schema-hint.sh. Uses a temporary HOME and cache
# and a small synthetic card with made-up names; the real card is never read.
# Usage: local-hooks/tests/run-brain-hint-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
unset BRAIN_SCHEMA_CARD XDG_CACHE_HOME
export XDG_CACHE_HOME="$HOME/cache"
card="$HOME/card.md"
export BRAIN_SCHEMA_CARD="$card"
hook="bash $hooks/brain-schema-hint.sh"

cat > "$card" <<'CARD'
# Fake card
## widgets  (a made-up table)
cols: id, label text REQ
## gadgets
cols: id, widget_id
## Enum values (exact)
gizmo_state: open, shut, ajar | note
## Common wrong guesses -> right name
| Wrong | Right | n |
|---|---|---|
| widgets.title / w.title | widgets.label | 5 |
| gadgets.title | gadgets.name | 2 |
CARD

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
fresh() { rm -rf "$XDG_CACHE_HOME"; }
# run PAYLOAD -> sets $out and $rc
run() { out="$(printf '%s' "$1" | $hook 2>&1)"; rc=$?; }
fail_ev() { jq -nc --arg t "$1" --arg e "$2" --arg q "${3:-select 1}" --arg id "${4:-tu1}" '{hook_event_name:"PostToolUseFailure",tool_name:$t,tool_input:{query:$q},tool_use_id:$id,error:$e}'; }
post_ev() { jq -nc --arg t "$1" --arg e "$2" --arg id "${3:-tu1}" '{hook_event_name:"PostToolUse",tool_name:$t,tool_input:{query:"select 1"},tool_use_id:$id,tool_response:{is_error:true,content:[{type:"text",text:$e}]}}'; }
has() { grep -qF -- "$2" <<<"$out" && ok "$1" || bad "$1" "missing [$2] in: $out"; }
silent() { if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "$1"; else bad "$1" "rc=$rc out=$out"; fi; }
T=mcp__brain__execute_sql

fresh; run "$(fail_ev $T 'ERROR: column "title" does not exist' 'select w.title from widgets w')"
has "column error: correction quoted" "widgets.title / w.title -> widgets.label"
has "column error: card path given" "$card"
jq -e '.hookSpecificOutput.hookEventName=="PostToolUseFailure" and (.hookSpecificOutput.additionalContext|length)<=1400' >/dev/null <<<"$out" && ok "failure event: valid JSON, event name, capped" || bad "json shape" "$out"
[ "$rc" -eq 0 ] && ok "exit 0 on hint" || bad "exit 0 on hint" "rc=$rc"
fresh; run "$(fail_ev $T 'column "title" of relation "gadgets" does not exist' 'insert into gadgets (title) values (1)')"
has "table in query picks the matching row first" "gadgets.title -> gadgets.name"
fresh; run "$(fail_ev $T 'ERROR: column "zzz" does not exist')"
has "unknown column: generic pointer" "is not in the card corrections"
has "unknown column: card path" "$card"
fresh; run "$(fail_ev $T 'ERROR: relation "wigdets" does not exist')"
has "relation error: card sections listed" "widgets, gadgets"
fresh; run "$(fail_ev $T 'ERROR: invalid input value for enum gizmo_state: "bogus"')"
has "enum error: allowed values" "gizmo_state: open, shut, ajar"
fresh; run "$(fail_ev $T 'ERROR: invalid input value for enum other_state: "x"')"
has "enum not in card: generic pointer" "is not in the card"
fresh; run "$(fail_ev $T 'ERROR: operator does not exist: uuid = integer')"
has "type error: pointer" "Type error"

fresh; run "$(fail_ev $T 'ERROR: permission denied for table widgets')"; silent "non-schema Brain error is silent"
fresh; run "$(fail_ev mcp__other__execute_sql 'ERROR: column "title" does not exist')"; silent "other MCP server is silent"
fresh; run "$(fail_ev Bash 'ERROR: column "title" does not exist')"; silent "non-MCP tool is silent"
fresh; run "$(fail_ev mcp__brain__ 'ERROR: column "title" does not exist')"; has "bare prefix tool name still matches" "Schema error"
fresh; BRAIN_SCHEMA_CARD="$HOME/none.md" run "$(fail_ev $T 'ERROR: column "title" does not exist')"; silent "missing card is silent"
fresh; run ''; silent "empty input is silent"
run '   '; silent "blank input is silent"
run '{not json'; silent "malformed JSON is silent"
run '[1,2]'; silent "non-object JSON is silent"
run '{"tool_name":null,"error":3}'; silent "odd field types are silent"
run '{"hook_event_name":"PreToolUse","tool_name":"mcp__brain__execute_sql","error":"column \"title\" does not exist"}'; silent "other event is silent"

fresh; run "$(post_ev $T 'ERROR: column "title" does not exist')"
has "PostToolUse error response: correction" "widgets.title / w.title -> widgets.label"
jq -e '.hookSpecificOutput.hookEventName=="PostToolUse"' >/dev/null <<<"$out" && ok "PostToolUse: event name echoed" || bad "event name" "$out"
fresh; run '{"hook_event_name":"PostToolUse","tool_name":"mcp__brain__execute_sql","tool_response":{"content":[{"type":"text","text":"column \"title\" does not exist"}]}}'; silent "PostToolUse without error flag is silent"
fresh; run '{"hook_event_name":"PostToolUse","tool_name":"mcp__brain__execute_sql","tool_response":"column \"title\" does not exist"}'; silent "PostToolUse string response without flag is silent"
fresh; run '{"hook_event_name":"PostToolUse","tool_name":"mcp__brain__execute_sql","tool_response":{"isError":true,"content":[{"type":"text","text":"boom"}]}}'; silent "PostToolUse non-schema error is silent"
fresh; run '{"tool_name":"mcp__brain__execute_sql","error":"column \"title\" does not exist"}'; has "no event name, error string: treated as failure" "Schema error"

# Duplicate suppression: both events for one call give one hint.
fresh
run "$(fail_ev $T 'ERROR: column "title" does not exist' 'select 1' dup1)"; has "dup: first event emits" "Schema error"
run "$(post_ev $T 'ERROR: column "title" does not exist' dup1)"; silent "dup: second event, same call id, is silent"
run "$(fail_ev $T 'ERROR: column "title" does not exist' 'select 1' dup1)"; silent "dup: repeat of same event, same id, is silent"
run "$(fail_ev $T 'ERROR: column "title" does not exist' 'select 1' dup2)"; has "dup: a different call id emits again" "Schema error"
fresh
run "$(post_ev $T 'ERROR: column "title" does not exist' dup3)"; has "dup: PostToolUse first emits" "Schema error"
run "$(fail_ev $T 'ERROR: column "title" does not exist' 'select 1' dup3)"; silent "dup: failure event after it is silent"
fresh
run "$(fail_ev $T 'ERROR: permission denied' 'select 1' dup4)"; silent "dup: silent first event leaves no marker"
run "$(fail_ev $T 'ERROR: column "title" does not exist' 'select 1' dup4)"; has "dup: later schema error on that id emits" "Schema error"
fresh
p="$(jq -nc --arg t "$T" '{hook_event_name:"PostToolUseFailure",tool_name:$t,tool_input:{query:"q"},error:"column \"title\" does not exist"}')"
run "$p"; has "no call id: first emits" "Schema error"
run "$p"; silent "no call id: identical repeat within seconds is silent"
fresh; run "$(fail_ev $T 'ERROR: column "title" does not exist' 'select 1' '../../etc/x y')"; has "odd call id is sanitised and works" "Schema error"
ls "$XDG_CACHE_HOME/claude-hooks" | grep -q '^brainhint\.id\.' && ok "marker file named from call id" || bad "marker naming"
# Cache location unwritable: still emits.
fresh; mkdir -p "$HOME/ro"; chmod 500 "$HOME/ro"
XDG_CACHE_HOME="$HOME/ro/c" run "$(fail_ev $T 'ERROR: column "title" does not exist')"; has "unwritable cache: still emits" "Schema error"
chmod 700 "$HOME/ro"

# Speed: one hint run well under 100 ms.
fresh; pl="$(fail_ev $T 'ERROR: column "title" does not exist' 'select 1' speed1)"
s=$(date +%s%N); printf '%s' "$pl" | $hook >/dev/null; e=$(date +%s%N)
ms=$(( (e - s) / 1000000 )); [ "$ms" -lt 100 ] && ok "hint run took ${ms} ms (< 100)" || bad "hint run took ${ms} ms"

# The script itself must carry no schema detail: no card contents, only generic text.
! grep -qE 'brain\.|fieozy|supabase' "$hooks/brain-schema-hint.sh" "$hooks/_brain-schema-hint.py" && ok "script has no project reference or schema names" || bad "script has schema detail"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
