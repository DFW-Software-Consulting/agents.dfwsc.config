#!/usr/bin/env bash
# Static checks on the Claude PR skills. Each section covers one skill; append
# a new section (and an entry in docs/context/hooks-testing.md) for the next.
# Usage: local-hooks/tests/run-pr-skills-tests.sh [SKILLS_DIR]
#   Default SKILLS_DIR is ../../skills relative to this file.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_dir="${1:-$here/../../skills}"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# --- pr-review: reviewed-head marker ---
f="$skills_dir/pr-review/SKILL.md"
if [ ! -f "$f" ]; then
  bad "pr-review: no $f"
else
  grep -q 'reviewed-head' "$f" && ok "pr-review: mentions reviewed-head" || bad "pr-review: no reviewed-head"
  grep -Fq '<!-- reviewed-head: <40-hex sha> -->' "$f" \
    && ok "pr-review: marker format documented" || bad "pr-review: marker format with 40-hex placeholder missing"
  # headRefOid must be inside the gh pr view --json field list
  if grep -E '^gh pr view .*--json [^ ]*\bheadRefOid\b' "$f" >/dev/null; then ok "pr-review: headRefOid in gh pr view --json fields"
  else bad "pr-review: headRefOid not in the gh pr view --json field list"; fi
  grep -qi 'exactly one PR comment' "$f" && ok "pr-review: exactly-one-comment rule kept" || bad "pr-review: exactly-one-comment rule missing"
  grep -qi 'at most one review comment' "$f" && ok "pr-review: at-most-one-review-comment rule kept" || bad "pr-review: at-most-one rule missing"
  # rejected case: no instruction to add a second comment or second marker line
  if grep -Ei '(add|append|post|write)[^.]*(second|another|additional|new) (reviewed-head|marker)' "$f" >/dev/null; then
    bad "pr-review: instructs adding a second marker"
  else ok "pr-review: no instruction to add a second marker"; fi
  grep -Eqi 'never (add|post)[^.]*second (marker|reviewed-head)|never adds? a second' "$f" \
    && ok "pr-review: forbids a second marker line" || bad "pr-review: does not forbid a second marker line"
  if grep -Ei '(post|add|write)[^.]*second review comment' "$f" | grep -Evi 'never|not|no ' >/dev/null; then
    bad "pr-review: instructs posting a second review comment"
  else ok "pr-review: no instruction to post a second review comment"; fi
  [ "$(grep -c '<!-- reviewed-head:' "$f")" -le 2 ] && ok "pr-review: marker literal not repeated" || bad "pr-review: marker literal appears too often"
  grep -Eqi 'no marker|without a marker|carries? no marker' "$f" && grep -qi 'not reviewed at this head' "$f" \
    && ok "pr-review: reader rule (no/stale marker = not reviewed at this head)" || bad "pr-review: reader rule missing"
  grep -Eqi 'local mode.*(no|never).*marker|no marker.*local' "$f" \
    && ok "pr-review: local mode gets no marker" || bad "pr-review: local-mode no-marker line missing"
  # voice: marker line itself must not name AI or tools
  if grep -E 'reviewed-head' "$f" | grep -Eqi '\b(claude|ai|agent|automat)'; then bad "pr-review: marker line mentions AI/agent"
  else ok "pr-review: marker lines carry no AI wording"; fi
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
