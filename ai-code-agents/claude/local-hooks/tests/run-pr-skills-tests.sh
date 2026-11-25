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

# --- pr-converge: skill, templates, goal-line ---
f="$skills_dir/pr-converge/SKILL.md"
t="$skills_dir/pr-converge/templates.md"
gl="$here/../../bin/goal-line"
if [ ! -f "$f" ]; then
  bad "pr-converge: no $f"
else
  [ "$(sed -n 's/^name: *//p' "$f" | head -1)" = "pr-converge" ] \
    && ok "pr-converge: frontmatter name equals folder" || bad "pr-converge: frontmatter name is not pr-converge"
  grep -Eqi '(at most|up to|maximum of|max) 3 rounds|3-round cap' "$f" && ok "pr-converge: 3-round cap" || bad "pr-converge: no 3-round cap"
  grep -qi 'never merges' "$f" && ok "pr-converge: never merges" || bad "pr-converge: no 'never merges'"
  grep -q 'DECISION: <exact command> | <why>' "$f" && ok "pr-converge: DECISION line format" || bad "pr-converge: DECISION line format missing"
  grep -q 'reviewed-head' "$f" && grep -qi 'not reviewed at this head' "$f" \
    && ok "pr-converge: marker rule" || bad "pr-converge: marker rule missing"
  grep -qi 'Done when' "$f" && ok "pr-converge: fix brief carries Done when" || bad "pr-converge: no Done when"
  grep -qi 'force push' "$f" && grep -qi 'promote' "$f" && ok "pr-converge: no force push, no promote" || bad "pr-converge: force push or promote rule missing"
  grep -q 'pr-land' "$f" && grep -q 'pr-wait' "$f" && ok "pr-converge: pr-land and pr-wait handled" || bad "pr-converge: pr-land or pr-wait missing"
  grep -qi 'never a sleep loop' "$f" && ok "pr-converge: no sleep loop" || bad "pr-converge: sleep-loop rule missing"
  grep -q '/ship' "$f" && grep -q '/steward' "$f" && ok "pr-converge: overlap stated" || bad "pr-converge: overlap section missing"
fi
if [ ! -f "$t" ]; then
  bad "pr-converge templates: no $t"
else
  for h in 'Ship-PR' 'Ops investigation' 'Backlog sweep' 'Overnight'; do
    grep -q "^## $h" "$t" && ok "templates: has $h" || bad "templates: missing $h"
  done
  tsec() { awk -v h="## $1" 'index($0,h)==1{p=1;next} /^## /{p=0} p' "$t"; }
  tsec 'Ship-PR' | grep -q 'Stop after 40 turns' && ok "templates: Ship-PR 40 turns" || bad "templates: Ship-PR 40 turns missing"
  tsec 'Ops investigation' | grep -q 'Stop after 15 turns' && ok "templates: Ops 15 turns" || bad "templates: Ops 15 turns missing"
  tsec 'Backlog sweep' | grep -q 'Stop after 40 turns' && ok "templates: Backlog 40 turns" || bad "templates: Backlog 40 turns missing"
  tsec 'Overnight' | grep -q 'Stop after 40 turns' && ok "templates: Overnight 40 turns" || bad "templates: Overnight 40 turns missing"
  for h in 'Ship-PR' 'Ops investigation' 'Backlog sweep' 'Overnight'; do
    tsec "$h" | grep -q 'DECISION: <exact command> | <why>' && ok "templates: $h DECISION text" || bad "templates: $h DECISION text missing"
  done
  tsec 'Ship-PR' | grep -qi 'ready to merge' && ok "templates: Ship-PR ends at ready to merge" || bad "templates: Ship-PR end missing"
  tsec 'Ship-PR' | grep -q 'under 1,000 characters' && ok "templates: Ship-PR reply cap" || bad "templates: Ship-PR reply cap missing"
  tsec 'Ops investigation' | grep -qi 'no writes' && ok "templates: Ops no writes" || bad "templates: Ops no writes missing"
  tsec 'Backlog sweep' | grep -qi 'exits 0' && tsec 'Backlog sweep' | grep -qi 'not merged' && ok "templates: Backlog exit 0, not merged" || bad "templates: Backlog end condition missing"
  ov="$(tsec 'Overnight')"
  grep -q 'claude --bg --permission-mode auto' <<<"$ov" && ok "templates: Overnight launch command" || bad "templates: Overnight launch command missing"
  grep -q "end states are the pr-converge skill's end states" <<<"$ov" && ok "templates: Overnight end states are the skill's" || bad "templates: Overnight end state missing"
  for n in 'never retry a denied action' 'never merge' 'never promote' 'never deploy' 'never run migrations' 'never read or write production' 'never write to shared databases'; do
    grep -qi "$n" <<<"$ov" && ok "templates: Overnight '$n'" || bad "templates: Overnight '$n' missing"
  done
  grep -qi 'table' <<<"$ov" && grep -q 'under 1,000 characters' <<<"$ov" && ok "templates: Overnight table reply under cap" || bad "templates: Overnight reply rule missing"
  grep -qi 'draft PR' <<<"$ov" && ok "templates: Overnight draft PR rule" || bad "templates: Overnight draft PR rule missing"
fi
if [ ! -f "$gl" ]; then
  bad "goal-line: no $gl"
else
  [ -x "$gl" ] && ok "goal-line: executable" || bad "goal-line: not executable"
  out="$("$gl" ship-pr octo/demo 7 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && ok "goal-line: ship-pr exits 0" || bad "goal-line: ship-pr exit $rc"
  grep -q 'octo/demo' <<<"$out" && grep -qw '7' <<<"$out" && grep -q 'Stop after 40 turns' <<<"$out" \
    && ok "goal-line: output has repo, PR, 40 turns" || bad "goal-line: output missing repo, PR or 40 turns"
  grep -q '{{' <<<"$out" && bad "goal-line: unfilled placeholder" || ok "goal-line: placeholders filled"
  "$gl" nope octo/demo 7 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "goal-line: unknown template exits 2" || bad "goal-line: unknown template exit $rc"
  "$gl" ship-pr octo/demo >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "goal-line: missing argument exits 2" || bad "goal-line: missing argument exit $rc"
  "$gl" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "goal-line: no arguments exits 2" || bad "goal-line: no arguments exit $rc"
fi
# hygiene: no host, address or real-repo identifiers in the new files
hy=""
for x in "$f" "$t" "$gl"; do [ -f "$x" ] && hy="$hy $x"; done
if [ -n "$hy" ] && grep -Eni '([0-9]{1,3}\.){3}[0-9]{1,3}|\.(ts\.net|com|dev|ai|app)\b|craft ?digital|dfwsc|@[a-z0-9-]+\.[a-z]' $hy >/dev/null; then
  bad "pr-converge: host, address or client identifier in new files"
else ok "pr-converge: no host, address or client identifiers"; fi

# --- pr-converge: review-fix checks (goal-line fill, wording, round 3) ---
if [ -x "$gl" ] && [ -f "$t" ] && [ -f "$f" ]; then
  tmpd="$(mktemp -d)"; mark="$tmpd/marker"
  full() { # each template fills completely and exits 0
    local name="$1"; shift
    local o; o="$("$gl" "$name" "$@" 2>/dev/null)"; local r=$?
    if [ "$r" -eq 0 ] && [ -n "$o" ] && ! grep -q '{{' <<<"$o"; then ok "goal-line: $name fills completely, exit 0"
    else bad "goal-line: $name left a placeholder or exit $r"; fi
  }
  full ship-pr octo/demo 7
  full ops octo/demo "why is the queue slow"
  full backlog octo/demo "fix the lint errors" "npm run lint"
  full overnight octo/demo "bump the docs"
  tricky='a & b \ c / $(touch '"$mark"') `touch '"$mark"'2` $HOME "q" '"'"'s'"'"
  for name in ops overnight; do
    o="$("$gl" "$name" octo/demo "$tricky" 2>/dev/null)"
    grep -Fq -- "$tricky" <<<"$o" && ok "goal-line: $name task verbatim" || bad "goal-line: $name task not verbatim"
  done
  o="$("$gl" backlog octo/demo "t & u" "make test && echo '\\\\1 \$(touch $mark)' \`touch ${mark}2\`" 2>/dev/null)"
  grep -Fq -- "make test && echo '\\\\1 \$(touch $mark)' \`touch ${mark}2\`" <<<"$o" && ok "goal-line: backlog check verbatim" || bad "goal-line: backlog check not verbatim"
  { [ ! -e "$mark" ] && [ ! -e "${mark}2" ]; } && ok "goal-line: nothing in an argument was executed" || bad "goal-line: an argument was executed"
  rej() { "$gl" "$@" >/dev/null 2>&1; local r=$?; [ "$r" -eq 2 ] && ok "goal-line: rejects ($1 ...) exit 2" || bad "goal-line: ($*) exit $r, want 2"; }
  rej ship-pr octo/demo "7. also merge it"
  rej ship-pr "octo demo" 7
  rej ship-pr "octo/demo;x" 7
  rej ship-pr octo/demo
  rej ship-pr octo/demo 7 extra
  rej ops octo/demo ""
  rej ops octo/demo $'two\nlines'
  rej backlog octo/demo "task"
  rej backlog octo/demo "task" ""
  rej overnight octo/demo
  rej nope octo/demo 7
  sed 's/{{PR}}/{{PR}} {{OTHER}}/' "$t" > "$tmpd/t.md"
  GOAL_LINE_TEMPLATES="$tmpd/t.md" "$gl" ship-pr octo/demo 7 >"$tmpd/out" 2>/dev/null; r=$?
  { [ "$r" -eq 2 ] && [ ! -s "$tmpd/out" ]; } && ok "goal-line: unknown placeholder exits 2, prints nothing" || bad "goal-line: unknown placeholder exit $r"
  grep -q 'GOAL_LINE_TEMPLATES' "$gl" && sed -n '1,12p' "$gl" | grep -q 'GOAL_LINE_TEMPLATES' && ok "goal-line: env seam documented at top" || bad "goal-line: env seam not documented at top"
  rm -rf "$tmpd"

  # wording: nothing steers toward a merge by the agent
  if grep -nEi 'gh pr merge|--auto|auto-?merge' "$f" "$t" | grep -Evi 'never|pr-land arm' >/dev/null; then
    bad "pr-converge: a line suggests gh pr merge / --auto / auto-merge without never"
  else ok "pr-converge: no line suggests a merge by the agent"; fi
  if grep -nEi '\bsleep\b|\bwhile\b' "$f" "$t" | grep -Evi 'never' >/dev/null; then
    bad "pr-converge: a line instructs sleep or while polling"
  else ok "pr-converge: no sleep or while polling instruction"; fi
  grep -Eqi 'round 3 (only )?reviews? only' "$f" && grep -Eqi 'without fixing or pushing|does not fix or push|no fix, no push' "$f" \
    && ok "pr-converge: round 3 reviews only, no fix or push" || bad "pr-converge: round 3 rule missing"
  grep -q 'gh pr view <pr> -R <owner/repo> --json headRefOid' "$f" && grep -qi 'never .*local checkout' "$f" \
    && ok "pr-converge: head re-read from GitHub after push" || bad "pr-converge: head re-read rule missing"
  grep -q 'Ready to merge' "$f" && grep -qi 'pending' "$f" && grep -qi 'failed' "$f" \
    && ok "pr-converge: ready verdict string and mixed cases" || bad "pr-converge: verdict string or mixed cases missing"
  grep -qi 'only watches' "$f" && grep -qi 'owner runs' "$f" && ok "pr-converge: pr-land sentence" || bad "pr-converge: pr-land sentence missing"
  ov="$(awk 'index($0,"## Overnight")==1{p=1;next} /^## /{p=0} p' "$t")"
  for n in 'never force push' 'never push to a default branch' 'launched this session himself' 'pushing its own branch, opening a draft pull request and posting the review' 'no retry and no other route'; do
    grep -qi -- "$n" <<<"$ov" && ok "templates: Overnight prompt has '$n'" || bad "templates: Overnight prompt lacks '$n'"
  done
  # review fixes: counted re-review, tier name, order of pushes, bounded wait, reader rule
  grep -Eqi 'every review run counts as a round' "$f" && grep -qi 'whatever triggered it' "$f" \
    && ok "pr-converge: every review run counts as a round" || bad "pr-converge: counted re-review rule missing"
  grep -Eqi 'stops? (at|after) the (round )?cap|after the third review' "$f" && grep -qi 'no extra review' "$f" \
    && ok "pr-converge: cap stops the run even after a marker mismatch" || bad "pr-converge: cap-after-mismatch rule missing"
  grep -q 'CONSIDER' "$f" && ! grep -q 'NITs' "$f" \
    && ok "pr-converge: CONSIDER tier, no NITs" || bad "pr-converge: NITs wording or CONSIDER missing"
  grep -q 'Reviewed-head marker' "$f" && grep -q 'amend rule' "$f" && grep -qi 'pr-review/SKILL.md' "$f" \
    && ok "pr-converge: reader rule points at the review skill" || bad "pr-converge: reader rule does not point at the review skill"
  grep -Eq 'pr-wait <owner/repo> <pr> --sha <H> --timeout [0-9]+m' "$f" \
    && ok "pr-converge: checks wait is bounded" || bad "pr-converge: checks wait has no timeout"
  grep -qi 'on timeout' "$f" && grep -qi 'do not loop' "$f" && ok "pr-converge: timeout stops and reports" || bad "pr-converge: timeout stop rule missing"
  # step A: the optional local-mode review is not counted
  a="$(awk -v s="**Step A:" 'index($0,s)==1{p=1;print;next} p && (/^\*\*Step [A-Z]:/ || /^## /){p=0} p' "$f")"
  grep -qi 'local-mode review' <<<"$a" && grep -qi 'does not count as a round' <<<"$a" \
    && ok "pr-converge: step A local review optional and uncounted" || bad "pr-converge: step A lacks the uncounted local review rule"
  # restructure: one canonical loop, steps A to E, each with one job
  sl() { grep -nE "^\*\*Step $1:" "$f" | cut -d: -f1; }
  steps_ok=1; prev=0
  for s in A B C D E; do
    c="$(grep -cE "^\*\*Step $s:" "$f")"; n="$(sl "$s" | head -1)"
    if [ "$c" -ne 1 ] || [ -z "$n" ] || [ "$n" -le "$prev" ]; then steps_ok=0; break; fi
    prev="$n"
  done
  [ "$steps_ok" -eq 1 ] && ok "pr-converge: step markers A to E appear once each, in order" || bad "pr-converge: step markers A to E missing, repeated or out of order"
  # a step's text runs from its marker to the next step marker or the next heading
  ssec() { awk -v s="**Step $1:" 'index($0,s)==1{p=1;print;next} p && (/^\*\*Step [A-Z]:/ || /^## /){p=0} p' "$f"; }
  succ_ok=1
  for s in A B C D E; do
    grep -Eq 'go to step [A-E]|END|stop with a DECISION line' <<<"$(ssec "$s")" || { succ_ok=0; bad "pr-converge: step $s names no successor"; }
  done
  [ "$succ_ok" -eq 1 ] && ok "pr-converge: every step names its successor"
  [ "$(grep -c 'A review starts only in step B' "$f")" -eq 1 ] && ok "pr-converge: review starts only in step B, said once" || bad "pr-converge: 'A review starts only in step B' not exactly once"
  [ "$(grep -c 'A fix is made only in step D' "$f")" -eq 1 ] && ok "pr-converge: fix made only in step D, said once" || bad "pr-converge: 'A fix is made only in step D' not exactly once"
  [ "$(grep -c 'Only step E waits' "$f")" -eq 1 ] && ok "pr-converge: only step E waits, said once" || bad "pr-converge: 'Only step E waits' not exactly once"
  # the cap is checked before the review in B and before the fix in D
  b="$(ssec B)"; d="$(ssec D)"
  { [ "$(grep -o 'If R is 3' <<<"$b" | wc -l)" -eq 1 ] \
    && awk -v x="$b" 'BEGIN{x=tolower(x); i=index(x,"if r is 3"); j=index(x,"run one pr-mode review"); exit !(i>0 && j>i)}'; } \
    && ok "pr-converge: step B checks the cap before starting a review" || bad "pr-converge: step B does not check the cap first"
  awk -v x="$d" 'BEGIN{x=tolower(x); i=index(x,"if r is 3"); j=index(x,"dispatch one fix agent"); exit !(i>0 && j>i)}' \
    && ok "pr-converge: step D checks the cap before any fix" || bad "pr-converge: step D does not check the cap before fixing"
  grep -q 'without fixing or pushing' <<<"$d" && ok "pr-converge: step D at the cap stops without fixing or pushing" || bad "pr-converge: step D cap stop rule missing"
  # the wait command appears once, inside step E
  e="$(ssec E)"
  [ "$(grep -c 'pr-wait <owner/repo> <pr> --sha <H> --timeout 60m' "$f")" -eq 1 ] && grep -q 'pr-wait <owner/repo> <pr> --sha <H> --timeout 60m' <<<"$e" \
    && ok "pr-converge: the wait command appears once, inside step E" || bad "pr-converge: wait command not exactly once inside step E"
  if grep -n 'gh pr checks.*--watch' "$f" "$t" >/dev/null; then bad "pr-converge: gh pr checks --watch fallback still present"
  else ok "pr-converge: no gh pr checks --watch fallback"; fi
  grep -q '124' "$f" && bad "pr-converge: fallback exit 124 still mapped" || ok "pr-converge: no exit 124 mapping"
  # each pr-wait exit code, matched with a boundary, maps to the successor in its own clause in step E
  xo() { grep -Eq "(^|[^0-9])$1 \\($2\\)[^.:]*: $3" <<<"$e"; }
  xo 0 green 'END' && ok "pr-converge: exit 0 (green) ends ready" || bad "pr-converge: exit 0 not mapped to END"
  xo 5 'no checks' 'END' && ok "pr-converge: exit 5 (no checks) ends ready" || bad "pr-converge: exit 5 not mapped to END"
  xo 1 failed 'go to step D' && ok "pr-converge: exit 1 (failed) goes to step D" || bad "pr-converge: exit 1 not mapped to step D"
  for p in '2 timeout' '3 head changed' '4 closed or merged' '10 usage or gh error'; do
    code="${p%% *}"; what="${p#* }"
    xo "$code" "$what" 'stop with a DECISION line' && ok "pr-converge: exit $code ($what) stops with DECISION" || bad "pr-converge: exit $code ($what) not mapped to a DECISION stop"
  done
  grep -qi 'not installed' <<<"$e" && grep -qi 'checks were not awaited' <<<"$e" && grep -qi 'do not substitute another command' <<<"$e" \
    && ok "pr-converge: pr-wait missing ends with a DECISION, no substitute" || bad "pr-converge: missing pr-wait rule absent"
  grep -q 'no second wait' <<<"$e" && ok "pr-converge: no second wait" || bad "pr-converge: second-wait rule missing"
  # templates and docs point at the loop and do not restate it
  ov="$(awk 'index($0,"## Overnight")==1{p=1;next} /^## /{p=0} p' "$t")"
  grep -q "pr-converge skill's loop from step A" <<<"$ov" && ok "templates: Overnight runs the skill's loop from step A" || bad "templates: Overnight does not name the skill's loop"
  grep -q "pr-converge skill's loop from step A" <<<"$(awk 'index($0,"## Ship-PR")==1{p=1;next} /^## /{p=0} p' "$t")" \
    && ok "templates: Ship-PR runs the skill's loop from step A" || bad "templates: Ship-PR does not name the skill's loop"
  if grep -Eqi 'after every push, including the first|each PR-mode review is one round|Flow: \(a\)' "$t"; then bad "templates: a second statement of the push and review order"
  else ok "templates: no second statement of the push and review order"; fi
  gdoc2="$here/../../../../docs/context/git-workflow-skills.md"
  if [ -f "$gdoc2" ]; then
    dsec="$(awk '/^## pr-converge/{p=1;next} /^## /{p=0} p' "$gdoc2")"
    if grep -Eqi 'after every push|a-d flow|gh pr checks --watch|green or no-checks' <<<"$dsec"; then bad "docs: pr-converge section restates the loop order"
    else ok "docs: pr-converge section points at the loop, no second copy"; fi
  fi
  # hygiene: no personal names or initials; also in the docs lines added
  if grep -nE '\bJC\b' "$f" "$t" "$gl" >/dev/null; then bad "pr-converge: a person's initials appear in S, T or G"
  else ok "pr-converge: no initials in S, T or G"; fi
  gdoc="$here/../../../../docs/context/git-workflow-skills.md"
  if [ -f "$gdoc" ]; then
    sec="$(awk '/^## pr-converge/{p=1;next} /^## /{p=0} p' "$gdoc")"
    if [ -z "$sec" ]; then bad "docs: no pr-converge section"
    elif grep -Eni '([0-9]{1,3}\.){3}[0-9]{1,3}|\.(ts\.net|com|dev|ai|app)\b|craft ?digital|dfwsc|\bJC\b' <<<"$sec" >/dev/null; then bad "docs: identifier in the pr-converge section"
    else ok "docs: pr-converge section has no identifiers"; fi
    grep -q 'goal-line backlog' <<<"$sec" && ok "docs: goal-line usage documented" || bad "docs: goal-line usage missing"
  fi
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
