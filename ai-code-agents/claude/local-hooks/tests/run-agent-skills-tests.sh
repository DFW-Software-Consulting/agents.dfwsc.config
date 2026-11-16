#!/usr/bin/env bash
# Checks that every skill listed in the `skills:` frontmatter of
# agents/git-workflow.md has a skills/<name>/SKILL.md whose `name` matches and
# which does not set disable-model-invocation: true. A wrong name is skipped
# silently when the agent starts, so this is the only guard.
# Usage: local-hooks/tests/run-agent-skills-tests.sh [AGENT_FILE]
#   Default AGENT_FILE is ../../agents/git-workflow.md; skills are looked up in
#   ../../skills relative to it.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent="${1:-$here/../../agents/git-workflow.md}"
skills_dir="$(cd "$(dirname "$agent")/../skills" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# names from the frontmatter list under `skills:` (first block only)
names="$(awk '
  NR==1 && $0=="---" {fm=1; next}
  fm && $0=="---" {exit}
  fm && /^skills:[[:space:]]*$/ {inl=1; next}
  fm && inl && /^[[:space:]]*-[[:space:]]+/ {sub(/^[[:space:]]*-[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; next}
  fm && inl {inl=0}
' "$agent")"
[ -n "$names" ] && ok "agent lists skills" || bad "agent has no skills list in frontmatter"
for n in $names; do
  f="$skills_dir/$n/SKILL.md"
  if [ ! -f "$f" ]; then bad "$n: no $f"; continue; fi
  fmname="$(awk 'NR==1&&$0=="---"{fm=1;next} fm&&$0=="---"{exit} fm&&/^name:/{sub(/^name:[[:space:]]*/,"");print;exit}' "$f")"
  [ "$fmname" = "$n" ] && ok "$n: name matches" || bad "$n: frontmatter name is [$fmname]"
  if awk 'NR==1&&$0=="---"{fm=1;next} fm&&$0=="---"{exit} fm&&/^disable-model-invocation:[[:space:]]*true/{f=1} END{exit !f}' "$f"; then
    bad "$n: sets disable-model-invocation"
  else ok "$n: preloadable"; fi
done
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
