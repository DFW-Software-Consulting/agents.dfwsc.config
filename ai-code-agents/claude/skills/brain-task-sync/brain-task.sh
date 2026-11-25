#!/usr/bin/env bash
# Saved Brain task for the current branch, kept in local git config
# (branch.<branch>.brain-task) so every worktree of the repository sees it and it is never
# committed. No database access.
# Usage: brain-task.sh <repo-dir> get | set <id> [--replace] | clear
#        brain-task.sh <repo-dir> project get | set <uuid> | clear
# `project` keeps the repository's Brain project id in git config brain.project-id (repo-wide,
# shared by all worktrees, never committed). Output project=<uuid>|none.
#   <id> is a task short_id (1 to 7 digits, no leading zero) or a task uuid (saved lowercase).
# Exit codes: 0 for everything except 2 (invalid id, bad invocation, not a repository on set).
# `set` on the default branch saves nothing: task=none reason=default-branch, exit 0.
# Output: key=value lines (branch=, task=<id>|none, detached=true, saved=false, replaced=<old>,
#   refused=different-task-saved old=<old>). Exit 0 except for an invalid id or a bad invocation.
dir="${1:-}"; cmd="${2:-}"
usage() { echo "usage: brain-task.sh <repo-dir> get | set <id> [--replace] | clear | project get|set <uuid>|clear" >&2; exit 2; }
[ -n "$dir" ] && [ -n "$cmd" ] || usage
command -v git >/dev/null 2>&1 || { echo "error=missing-tool:git"; exit 0; }
valid() { [[ "$1" =~ ^[1-9][0-9]{0,6}$ ]] || [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [ "$cmd" = project ]; then
  sub="${3:-}"
  case "$sub" in
    get|clear) [ "$#" -eq 3 ] || usage ;;
    set) [ "$#" -eq 4 ] || usage
         [[ "$4" =~ $UUID_RE ]] || { echo "error=invalid-id" >&2; echo "error=invalid-id"; exit 2; } ;;
    *) usage ;;
  esac
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo "error=not-a-repo"; echo "project=none"; [ "$sub" = set ] && exit 2; exit 0; }
  cur="$(git -C "$dir" config --local --get brain.project-id 2>/dev/null)"
  [[ "$cur" =~ $UUID_RE ]] || cur=""
  case "$sub" in
    get) echo "project=${cur:-none}" ;;
    clear) git -C "$dir" config --local --unset-all brain.project-id 2>/dev/null; rc=$?
           # 5 = the key was already absent (a clean clear); anything else left the value in place
           if [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ]; then echo "project=none"; else echo "error=config-write-failed"; fi ;;
    set) new="${4,,}"; git -C "$dir" config --local brain.project-id "$new" || { echo "error=config-write-failed"; exit 0; }; echo "project=$new" ;;
  esac
  exit 0
fi
case "$cmd" in
  get|clear) [ "$#" -eq 2 ] || usage ;;
  set) [ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
       if [ "$#" -eq 4 ] && [ "$4" != "--replace" ]; then usage; fi
       valid "$3" || { echo "error=invalid-id" >&2; echo "error=invalid-id"; exit 2; } ;;
  *) usage ;;
esac
if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then echo "error=not-a-repo"; echo "task=none"; [ "$cmd" = set ] && exit 2; exit 0; fi
branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)"
if [ -z "$branch" ]; then
  echo "branch="; echo "task=none"; echo "detached=true"
  [ "$cmd" = set ] && echo "saved=false"
  exit 0
fi
if [ "$cmd" = set ]; then
  # the default branch (main, master, or what origin/HEAD names) is shared work, not one task's
  dflt="$(git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"; dflt="${dflt#refs/remotes/origin/}"
  if [ "$branch" = main ] || [ "$branch" = master ] || { [ -n "$dflt" ] && [ "$branch" = "$dflt" ]; }; then
    echo "branch=$branch"; echo "task=none reason=default-branch"; exit 0
  fi
fi
key="branch.$branch.brain-task"
old="$(git -C "$dir" config --local --get "$key" 2>/dev/null)"
valid "$old" || old=""
echo "branch=$branch"
case "$cmd" in
  get) echo "task=${old:-none}" ;;
  clear) git -C "$dir" config --local --unset-all "$key" 2>/dev/null; rc=$?
         # 5 = the key was already absent (a clean clear); anything else left the value in place
         if [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ]; then echo "task=none"; else echo "error=config-write-failed"; fi ;;
  set)
    new="${3,,}"
    if [ -n "$old" ] && [ "$old" != "$new" ] && [ "${4:-}" != "--replace" ]; then
      echo "refused=different-task-saved old=$old"; echo "task=$old"; exit 0
    fi
    [ -n "$old" ] && [ "$old" != "$new" ] && echo "replaced=$old"
    git -C "$dir" config --local "$key" "$new" || { echo "error=config-write-failed"; exit 0; }
    echo "task=$new" ;;
esac
exit 0
