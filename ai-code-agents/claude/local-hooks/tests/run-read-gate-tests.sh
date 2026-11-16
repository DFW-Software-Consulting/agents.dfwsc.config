#!/usr/bin/env bash
# Payload-driven tests for read-size-gate.sh. Runs against the repo copy with a
# temporary HOME so live gate off-files are never read.
# Usage: local-hooks/tests/run-read-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_DELEGATE_GATE CLAUDE_DELEGATE_GATE_OFF_FILE CLAUDE_READ_GATE_MAX_LINES CLAUDE_READ_GATE_MAX_BYTES
gate="bash $hooks/read-size-gate.sh"
w="$HOME/work"; mkdir -p "$w" "$w/a dir" "$w/subdir"
scratch="$HOME/scratch"; mkdir -p "$scratch"

pass=0; fail=0
# check NAME EXPECT(deny|allow) PAYLOAD [env assignments via ENVV]
check() {
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | env $ENVV $gate 2>&1)"; rc=$?
  if grep -q '"permissionDecision": *"deny"' <<<"$out"; then got=deny; else got=allow; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then pass=$((pass + 1)); echo "ok   - $name"
  else fail=$((fail + 1)); echo "FAIL - $name (expected $expect, got $got, rc=$rc)"; echo "       output: $out"; fi
}
ENVV="A=1"
rd() { jq -n --arg p "$1" --arg c "${2:-}" '{tool_name:"Read",cwd:$c,tool_input:{file_path:$p}}'; }
rdx() { jq -n --arg p "$1" --argjson x "$2" '{tool_name:"Read",tool_input:({file_path:$p}+$x)}'; }

seq 1 10 > "$w/small.txt"
seq 1 300 > "$w/l300.txt"
seq 1 301 > "$w/l301.txt"
head -c 40000 /dev/zero | tr '\0' 'x' > "$w/wide.txt"; echo >> "$w/wide.txt"   # 1 line, over bytes
head -c 5000000 /dev/zero | tr '\0' 'y' | fold -w 80 > "$w/big5mb.txt"
head -c 50000 /dev/urandom > "$w/blob.bin"
head -c 50000 /dev/zero > "$w/zeros.dat"
seq 1 500 > "$w/some file.txt"
seq 1 500 > "$w/subdir/rel.txt"
seq 1 500 > "$HOME/.claude/big-memory.md"
seq 1 500 > "$scratch/big.log"
seq 1 500 > "$w/doc.pdf"
seq 1 500 > "$w/nb.ipynb"

check "small file allowed" allow "$(rd "$w/small.txt")"
check "301-line file denied" deny "$(rd "$w/l301.txt")"
check "300-line file allowed" allow "$(rd "$w/l300.txt")"
check "over byte threshold with one line denied" deny "$(rd "$w/wide.txt")"
check "limit 100 on large file allowed" allow "$(rdx "$w/l301.txt" '{"limit":100}')"
check "limit 300 allowed" allow "$(rdx "$w/l301.txt" '{"limit":300}')"
check "limit 301 denied" deny "$(rdx "$w/l301.txt" '{"limit":301}')"
check "offset and limit allowed" allow "$(rdx "$w/wide.txt" '{"offset":200,"limit":50}')"
check "offset alone on large file denied" deny "$(rdx "$w/l301.txt" '{"offset":10}')"
check "limit as string number allowed" allow "$(rdx "$w/l301.txt" '{"limit":"50"}')"
check "non-numeric limit treated as absent (denied)" deny "$(rdx "$w/l301.txt" '{"limit":"abc"}')"
check "subagent payload allowed" allow "$(jq -n --arg p "$w/l301.txt" '{agent_id:"a1",tool_input:{file_path:$p}}')"
check "allowlisted .claude path allowed when large" allow "$(rd "$HOME/.claude/big-memory.md")"
check "scratchpad path allowed when large" allow "$(jq -n --arg p "$scratch/big.log" --arg s "$scratch" '{scratchpad_dir:$s,tool_input:{file_path:$p}}')"
check "same file outside scratchpad denied" deny "$(jq -n --arg p "$w/l301.txt" --arg s "$scratch" '{scratchpad_dir:$s,tool_input:{file_path:$p}}')"
check "random binary allowed" allow "$(rd "$w/blob.bin")"
check "NUL-filled file allowed" allow "$(rd "$w/zeros.dat")"
check ".pdf extension allowed" allow "$(rd "$w/doc.pdf")"
check ".ipynb extension allowed" allow "$(rd "$w/nb.ipynb")"
check "pages given allowed" allow "$(rdx "$w/l301.txt" '{"pages":"1-3"}')"
check "missing file allowed" allow "$(rd "$w/nope.txt")"
check "directory allowed" allow "$(rd "$w/subdir")"
check "path with spaces denied when large" deny "$(rd "$w/some file.txt")"
check "path in directory with spaces, small allowed" allow "$(rd "$w/a dir")"
check "relative path resolved against cwd denied" deny "$(rd "subdir/rel.txt" "$w")"
check "relative path without cwd allowed" allow "$(rd "subdir/rel.txt")"
check "5 MB file handled" deny "$(rd "$w/big5mb.txt")"
start=$SECONDS; echo "$(rd "$w/big5mb.txt")" | bash $hooks/read-size-gate.sh >/dev/null; el=$((SECONDS - start))
if [ "$el" -le 2 ]; then pass=$((pass + 1)); echo "ok   - 5 MB file decided in ${el}s"; else fail=$((fail + 1)); echo "FAIL - 5 MB file took ${el}s"; fi

# gate off
CLAUDE_DELEGATE_GATE=off; ENVV="CLAUDE_DELEGATE_GATE=off"
check "env gate off allowed" allow "$(rd "$w/l301.txt")"
ENVV="A=1"
touch "$HOME/.claude/delegate-gate.off"
check "fresh off-file allowed" allow "$(rd "$w/l301.txt")"
rm -f "$HOME/.claude/delegate-gate.off"

# env overrides
ENVV="CLAUDE_READ_GATE_MAX_LINES=5"
check "MAX_LINES=5 denies 10-line file" deny "$(rd "$w/small.txt")"
ENVV="CLAUDE_READ_GATE_MAX_LINES=1000"
check "MAX_LINES=1000 allows 301 lines" allow "$(rd "$w/l301.txt")"
ENVV="CLAUDE_READ_GATE_MAX_BYTES=10"
check "MAX_BYTES=10 denies small file" deny "$(rd "$w/small.txt")"
ENVV="CLAUDE_READ_GATE_MAX_BYTES=100000"
check "MAX_BYTES=100000 allows 40000-byte line" allow "$(rd "$w/wide.txt")"
ENVV="CLAUDE_READ_GATE_MAX_LINES=abc"
check "bad MAX_LINES falls back (301 denied)" deny "$(rd "$w/l301.txt")"
ENVV="CLAUDE_READ_GATE_MAX_LINES=-4"
check "negative MAX_LINES falls back (300 allowed)" allow "$(rd "$w/l300.txt")"
ENVV="CLAUDE_READ_GATE_MAX_BYTES=0"
check "zero MAX_BYTES falls back (small allowed)" allow "$(rd "$w/small.txt")"
ENVV="A=1"

# shape of denial
out="$(rd "$w/l301.txt" | $gate)"
if jq -e '.hookSpecificOutput | .hookEventName=="PreToolUse" and .permissionDecision=="deny" and (.permissionDecisionReason|test("301 lines") and test("subagent") and test("offset and limit"))' >/dev/null 2>&1 <<<"$out"; then pass=$((pass + 1)); echo "ok   - denial JSON shape and reason (lines)"; else fail=$((fail + 1)); echo "FAIL - denial shape: $out"; fi
out="$(rd "$w/wide.txt" | $gate)"
if jq -e '.hookSpecificOutput.permissionDecisionReason | test("40001 bytes")' >/dev/null 2>&1 <<<"$out"; then pass=$((pass + 1)); echo "ok   - denial reason names bytes"; else fail=$((fail + 1)); echo "FAIL - bytes reason: $out"; fi

# fail open
for bad in '' 'not json' '[1,2]' '{}' '{"tool_input":{}}'; do
  out="$(printf '%s' "$bad" | $gate 2>&1)"; rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then pass=$((pass + 1)); echo "ok   - silent on input: ${bad:-<empty>}"; else fail=$((fail + 1)); echo "FAIL - input '$bad': rc=$rc out=$out"; fi
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
