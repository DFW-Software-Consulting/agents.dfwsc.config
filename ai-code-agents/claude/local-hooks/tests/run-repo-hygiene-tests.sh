#!/usr/bin/env bash
# Repository hygiene: no tracked file under docs/ and no tracked Markdown file
# may contain a leftover merge-conflict marker line (`<<<<<<< ` or `>>>>>>> `).
# Dependency-free (bash, git, grep). Also proves the check itself fails on a
# scratch repository that has a marker.
# Usage: run-repo-hygiene-tests.sh [repo root]   (default: the repo holding this script)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }

# markers ROOT: print "file:line:text" for each marker line in tracked docs/ and *.md files.
markers() {
  (cd "$1" && git ls-files -z -- 'docs' '*.md' | xargs -0 -r grep -n -H -E '^(<<<<<<<|>>>>>>>) ' 2>/dev/null)
}

root="${1:-$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$root" ] || ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "not inside a git repository"; echo "passed: 0  failed: 1"; exit 1
fi
hits="$(markers "$root")"
if [ -z "$hits" ]; then ok "no conflict markers in tracked docs or Markdown files"; else bad "conflict markers found" "$(printf '%s' "$hits" | head -5 | tr '\n' ' ')"; fi

# The check must catch a marker (scratch repository, never the real one).
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch/r"; mkdir -p "$scratch/r/docs/x"
printf 'clean\n' > "$scratch/r/docs/x/a.txt"; printf '# t\n' > "$scratch/r/README.md"
git -C "$scratch/r" add -A
[ -z "$(markers "$scratch/r")" ] && ok "scratch repo without markers is clean" || bad "scratch repo falsely flagged"
printf 'a\n<<<<<<< HEAD\nb\n' >> "$scratch/r/docs/x/a.txt"; git -C "$scratch/r" add -A
[ -n "$(markers "$scratch/r")" ] && ok "marker in a tracked docs file is caught" || bad "docs marker missed"
git -C "$scratch/r" checkout -q -- . 2>/dev/null; git -C "$scratch/r" reset -q; printf 'clean\n' > "$scratch/r/docs/x/a.txt"
printf 'x\n>>>>>>> abc123 (msg)\n' >> "$scratch/r/README.md"; git -C "$scratch/r" add -A
[ -n "$(markers "$scratch/r")" ] && ok "marker in a tracked Markdown file is caught" || bad "markdown marker missed"
printf '# t\nsetext\n=======\n' > "$scratch/r/README.md"; git -C "$scratch/r" add -A
[ -z "$(markers "$scratch/r")" ] && ok "a Markdown heading underline is not a marker" || bad "underline falsely flagged"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
