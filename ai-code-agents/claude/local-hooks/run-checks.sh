#!/usr/bin/env bash
# Run a repository's checks for its current commit and record the result in a
# stamp file inside the worktree's git dir. Run on request only (git-verify
# skill), never from a hook. Logic lives in _run_checks.py; detection and the
# stamp format in _checks_stamp.py.
#
# Usage: run-checks.sh [--dir <path>] [--build]
# Env:   CLAUDE_CHECKS_TIMEOUT  seconds per command (default 900; timeout = exit 124)
# Stdout: one JSON object. Exit: 0 passed/none_detected, 1 failed,
#         2 not a repo or no commits, 3 tracked files dirty.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec python3 "$here/_run_checks.py" "$@"
