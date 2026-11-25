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

  # --- marker contract: pattern taken from the skill text, run on sample bodies ---
  pat_line="$(grep -F '`^<!-- reviewed-head: ' "$f" | head -n1)"
  pat="$(printf '%s' "$pat_line" | grep -o '`^<!-- reviewed-head: [^`]*`' | head -n1 | tr -d '`')"
  want='^<!-- reviewed-head: ([0-9a-f]{40}) -->$'
  [ -n "$pat" ] && [ "$pat" = "$want" ] \
    && ok "pr-review: skill documents the anchored reader pattern" || bad "pr-review: anchored reader pattern missing or changed (got: ${pat:-none})"
  # reader: last line of the body (one final line break ignored) must match the
  # pattern and be preceded by one blank line; prints the sha, else nothing.
  read_marker() {
    local -a ls; mapfile -t ls < <(printf '%s' "$1")
    local n=${#ls[@]}
    [ "$n" -ge 2 ] || return 0
    [ -z "${ls[n-2]}" ] || return 0
    [[ "${ls[n-1]}" =~ ^'<!-- reviewed-head: '([0-9a-f]{40})' -->'$ ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
  }
  # the same check done with the pattern extracted from the skill text
  read_with_skill_pat() {
    [ -n "$pat" ] || return 0
    local -a ls; mapfile -t ls < <(printf '%s' "$1")
    local n=${#ls[@]}
    [ "$n" -ge 2 ] || return 0
    [ -z "${ls[n-2]}" ] || return 0
    printf '%s\n' "${ls[n-1]}" | grep -Eq -- "$pat" && printf '%s' "${ls[n-1]}" | sed -E 's/^<!-- reviewed-head: ([0-9a-f]{40}) -->$/\1/'
    return 0
  }
  sha=0123456789abcdef0123456789abcdef01234567
  other=fedcba9876543210fedcba9876543210fedcba98
  body="## Code Review — T (#5)"$'\n\n'"text"$'\n\n'"<!-- reviewed-head: $sha -->"
  check_case() { # name body expected-sha-or-empty
    local got; got="$(read_with_skill_pat "$2")"
    [ -n "$pat" ] && [ "$got" = "$3" ] && ok "pr-review: marker case: $1" || bad "pr-review: marker case: $1 (got '${got}', want '$3')"
  }
  check_case "final-line marker accepted" "$body" "$sha"
  check_case "final line break after marker accepted" "$body"$'\n' "$sha"
  check_case "marker quoted mid-body, text after it, rejected" "## Code Review — T (#5)"$'\n\n'"I saw <!-- reviewed-head: $sha --> quoted"$'\n\n'"end" ""
  check_case "marker quoted on its own line mid-body rejected" "## Code Review — T (#5)"$'\n\n'"<!-- reviewed-head: $sha -->"$'\n\n'"more text" ""
  check_case "uppercase value rejected" "text"$'\n\n'"<!-- reviewed-head: ${sha^^} -->" ""
  check_case "39-character value rejected" "text"$'\n\n'"<!-- reviewed-head: ${sha:0:39} -->" ""
  check_case "41-character value rejected" "text"$'\n\n'"<!-- reviewed-head: ${sha}0 -->" ""
  check_case "placeholder value rejected" "text"$'\n\n'"<!-- reviewed-head: <40-hex sha> -->" ""
  check_case "trailing spaces rejected" "text"$'\n\n'"<!-- reviewed-head: $sha -->  " ""
  check_case "two final line breaks rejected" "text"$'\n\n'"<!-- reviewed-head: $sha -->"$'\n\n' ""
  check_case "missing blank line before marker rejected" "text"$'\n'"<!-- reviewed-head: $sha -->" ""
  check_case "no marker means not reviewed" "$(printf '## Code Review — T (#5)\n\ntext')" ""
  check_case "two markers: only the last line counts" "x"$'\n\n'"<!-- reviewed-head: $other -->"$'\n\n'"<!-- reviewed-head: $sha -->" "$sha"
  # the test's own reader and the skill pattern must agree
  [ "$(read_marker "$body")" = "$sha" ] && [ -z "$(read_marker "text"$'\n'"<!-- reviewed-head: $sha -->")" ] \
    && ok "pr-review: pinned reader agrees with the skill pattern" || bad "pr-review: pinned reader disagrees"
  # template ends with a blank line then the marker line, nothing after
  tmpl_tail="$(awk '/^```markdown/{b=1;next} b&&/^```/{exit} b{print}' "$f" | tail -n 2)"
  [ "$tmpl_tail" = $'\n<!-- reviewed-head: <40-hex sha> -->' ] \
    && ok "pr-review: Report format template ends with blank line + marker" || bad "pr-review: template does not end with blank line + marker"
  # which comment a reader trusts
  grep -Fq 'only the comment the amend rule selects' "$f" && grep -Eqi 'authenticated login' "$f" \
    && ok "pr-review: reader trusts only the comment selected by the amend rule" || bad "pr-review: reader rule does not name the amend-rule comment"
  grep -Eqi 'omit the marker' "$f" && grep -Eqi 'never a placeholder' "$f" \
    && ok "pr-review: omit marker when head unavailable, no placeholder" || bad "pr-review: unavailable-head rule missing"
  grep -Eqi 'exactly one marker line' "$f" \
    && ok "pr-review: re-review leaves exactly one marker line" || bad "pr-review: exactly-one-marker-line rule missing"
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
