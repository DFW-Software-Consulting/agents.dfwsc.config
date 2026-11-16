#!/bin/bash
# Machine-wide, warn-only reminder (never blocks): when Claude runs git commit,
# git push, or gh pr create and the change touches non-doc files with nothing
# matching a doc pattern (README/CHANGELOG/.md/docs/ or reviews/), nudge to
# document the behavior change. Silent if nothing to say, or if the change
# genuinely looks doc-only / trivial.
set -uo pipefail

mode="$1"   # "pre" (PreToolUse, snapshots pre-push upstream) or "post" (PostToolUse, checks + reports)
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

has_commit=0; has_push=0; has_pr=0
printf '%s' "$cmd" | grep -qE '\bgit[[:space:]]+commit\b' && has_commit=1
printf '%s' "$cmd" | grep -qE '\bgit[[:space:]]+push\b' && has_push=1
printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+create\b' && has_pr=1

[ "$has_commit" -eq 0 ] && [ "$has_push" -eq 0 ] && [ "$has_pr" -eq 0 ] && exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0
statefile="/tmp/.claude-behavior-doc-check-$(printf '%s' "$root" | cksum | cut -d' ' -f1)"

if [ "$mode" = "pre" ]; then
  [ "$has_push" -eq 1 ] || exit 0
  git rev-parse '@{u}' 2>/dev/null > "$statefile" || rm -f "$statefile" 2>/dev/null
  exit 0
fi

# mode = post
doc_pattern='\.md$|^docs/|^reviews/|(^|/)README|(^|/)CHANGELOG'
files=""
ops=""

if [ "$has_commit" -eq 1 ]; then
  c=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null)
  if [ -n "$c" ]; then
    files="$files
$c"
    ops="committed"
  fi
fi

if [ "$has_push" -eq 1 ]; then
  before=$(cat "$statefile" 2>/dev/null)
  rm -f "$statefile" 2>/dev/null
  if [ -n "$before" ]; then
    p=$(git diff --name-only "$before"..HEAD 2>/dev/null)
    if [ -n "$p" ]; then
      files="$files
$p"
      ops="${ops:+$ops/}pushed"
    fi
  fi
fi

if [ "$has_pr" -eq 1 ]; then
  base=$(printf '%s' "$cmd" | grep -oE -- '--base[[:space:]=]+[^[:space:]]+|-B[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/^(--base[[:space:]=]+|-B[[:space:]]+)//')
  if [ -z "$base" ]; then
    base=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  fi
  [ -z "$base" ] && base="main"
  pr_diff=""
  if git rev-parse --verify -q "origin/$base" >/dev/null 2>&1; then
    pr_diff=$(git diff --name-only "origin/$base...HEAD" 2>/dev/null)
  elif git rev-parse --verify -q "$base" >/dev/null 2>&1; then
    pr_diff=$(git diff --name-only "$base...HEAD" 2>/dev/null)
  fi
  if [ -n "$pr_diff" ]; then
    files="$files
$pr_diff"
    ops="${ops:+$ops/}opened a PR"
  fi
fi

files=$(printf '%s\n' "$files" | sed '/^$/d' | sort -u)
[ -z "$files" ] && exit 0

total=$(printf '%s\n' "$files" | grep -vcE "$doc_pattern")
docs=$(printf '%s\n' "$files" | grep -cE "$doc_pattern")

if [ "$total" -gt 0 ] && [ "$docs" -eq 0 ]; then
  n=$(printf '%s\n' "$files" | grep -c .)
  reponame=$(basename "$root")
  jq -n --arg r "$reponame" --arg n "$n" --arg o "$ops" \
    '{systemMessage: ("Reminder: " + $o + " in " + $r + " touched " + $n + " file(s), none docs/reviews/README/CHANGELOG. If this changed behavior, document it (STACK_OVERVIEW.md, docs/, or a dated reviews/ file where that convention applies) — or note why not (pure bugfix, no behavior change, etc.).")}'
fi
