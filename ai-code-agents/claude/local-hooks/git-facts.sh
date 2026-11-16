#!/usr/bin/env bash
# Print one JSON object of repository facts the git skills need (root, branch,
# default branch, upstream and ahead/behind, clean tree, linked worktree, PR and
# issue template paths, commitlint, repository hooks, CODEOWNERS, changed-line
# counts against the default branch). Read-only: only queries git and reads
# files. Logic lives in _git_facts.py.
#
# Usage: git-facts.sh [--dir <path>]
# Stdout: one JSON object. Exit: 0 facts printed, 2 not a repository or bad
#         arguments (stdout is then {"error": "...", "dir": "..."}).
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec python3 -I "$here/_git_facts.py" "$@"
