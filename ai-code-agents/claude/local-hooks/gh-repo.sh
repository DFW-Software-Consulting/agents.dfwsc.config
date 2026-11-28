#!/usr/bin/env bash
# Print the repository (OWNER/REPO) the git-pr and git-issue skills pass to gh
# as --repo, resolved from the push remote of the current branch (pushRemote,
# else remote.pushDefault, else the branch's remote, else origin). Read-only:
# only queries git; never runs gh. Logic lives in _gh_repo.py.
#
# Usage: gh-repo.sh [--dir <path>]
# Stdout: {"repo":"OWNER/REPO","remote":"origin","branch":"feat"} (exit 0), or
#         {"error":"not-a-repo|no-remote|push-disabled|unresolvable|usage","message":"..."} (exit 2).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec python3 -I "$here/_gh_repo.py" "$@"
