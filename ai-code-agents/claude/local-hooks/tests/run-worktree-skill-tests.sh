#!/usr/bin/env bash
# Static checks for the worktree-hygiene skill: the retired force-removing wt-cleanup helper must not
# ship or be recommended, and the skill must point at wt-reap. Reads files only; nothing is run.
# Only the Claude copy is covered (the other harness copies are not changed by this check's change).
# Usage: local-hooks/tests/run-worktree-skill-tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude="$(cd "$here/../.." && pwd)"
skill_dirs=("$claude/skills/worktree-hygiene")
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# Lines that instruct running a retired or forcing command. A line that also carries a word of
# prohibition or retirement (never, not, don't, retired, instead) only mentions it, and is allowed.
instructing_lines() {
  grep -nE '(^|[^A-Za-z-])wt-cleanup|git worktree remove[^`]*(--force|-f( |$))|git branch -D' "$1" \
    | grep -viE 'never|do not|don.t|not |retired|instead' || true
}

for d in "${skill_dirs[@]}"; do
  label="${d#"$claude"/}"
  if find "$d" -iname 'wt-cleanup*' | grep -q .; then bad "$label: a wt-cleanup file still exists"; else ok "$label: no wt-cleanup file"; fi
  skill="$d/SKILL.md"
  grep -q 'wt-reap' "$skill" && ok "$label: SKILL.md names wt-reap" || bad "$label: SKILL.md does not name wt-reap"
  hits="$(instructing_lines "$skill")"
  if [ -z "$hits" ]; then ok "$label: SKILL.md instructs no wt-cleanup, forced worktree removal or branch -D"
  else bad "$label: SKILL.md instructs a retired or forcing command"; sed 's/^/       /' <<<"$hits"; fi
  inst="$d/scripts/wt-install.sh"
  if grep -q 'wt-cleanup' "$inst"; then bad "$label: wt-install.sh mentions wt-cleanup"; else ok "$label: wt-install.sh does not mention wt-cleanup"; fi
  bash -n "$inst" 2>/dev/null && ok "$label: bash -n wt-install.sh" || bad "$label: bash -n wt-install.sh fails"
done

# The detector itself: it must flag instructing lines and let prohibitions through.
fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
expect_flag() {  # NAME LINE flagged|clean
  printf '%s\n' "$2" > "$fx/l.md"
  if [ -n "$(instructing_lines "$fx/l.md")" ]; then got=flagged; else got=clean; fi
  [ "$got" = "$3" ] && ok "detector: $1 ($3)" || bad "detector: $1 (expected $3, got $got)"
}
expect_flag "instruction to force-remove a worktree" 'git worktree remove --force ../wt' flagged
expect_flag "instruction to delete a branch with -D" 'git branch -D feature' flagged
expect_flag "instruction to run wt-cleanup" 'wt-cleanup.sh --dry-run' flagged
expect_flag "prohibition of force removal" 'Never run `git worktree remove --force` or `git branch -D`.' clean
expect_flag "retirement note" '`wt-cleanup` was retired because it forced removals.' clean

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
