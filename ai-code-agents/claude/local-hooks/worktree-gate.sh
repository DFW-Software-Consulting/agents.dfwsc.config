#!/usr/bin/env bash
# PreToolUse gate: all work in a git repo happens in a linked worktree, never
# in the repo's primary checkout. Applies to the main session AND subagents.
#
# Register on PreToolUse with matchers `Edit|Write|NotebookEdit` and `Bash`.
#
# A directory is a PRIMARY checkout when it is inside a git work tree and its
# absolute git dir equals the absolute common git dir (a linked worktree's git
# dir lives under <common>/worktrees/). A submodule is judged by its superproject.
#
# File tools: deny edits to files in a primary checkout (symlinks resolved
# first). Allowed: outside any repo, unborn repos, linked worktrees, git-ignored paths.
# Bash: deny git subcommands that change HEAD, the index or the working tree
# when the effective directory (payload cwd, `cd`, `git -C`, `env -C`, `bash -c`
# bodies; a literal path or a plain variable assignment certain to have run) is a
# primary checkout. When the directory cannot be established (a variable that is
# not certain, a substitution, `cd -`, ...) such a command is denied too: write
# the directory literally. A `mktemp -d` directory on the same line is allowed.
# Read-only git commands are never judged. Parsing: _worktree-gate-check.py
# (uses _cmd_dirs.py and _git-cmd-scan.py).
#
# Fails open everywhere: bad input, missing jq/git/python3, undeterminable state.
# Escape hatch: CLAUDE_WORKTREE_GATE=off, or touch ~/.claude/worktree-gate.off
# (path overridable with CLAUDE_WORKTREE_GATE_OFF_FILE); the off-file expires
# after 12 hours (see _gate-common.sh).
set -uo pipefail
payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
WT_OFF_FILE="${CLAUDE_WORKTREE_GATE_OFF_FILE:-$HOME/.claude/worktree-gate.off}"
if source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  wt_off_state() { gate_off_file_state_for "$WT_OFF_FILE"; }
else
  # Shared file unavailable: behave as gate ON.
  wt_off_state() { echo none; }
fi
[ "${CLAUDE_WORKTREE_GATE:-on}" = "off" ] && exit 0
off_state="$(wt_off_state)"
[ "$off_state" = "fresh" ] && exit 0

deny() {
  local note=""
  [ "$off_state" = "stale" ] && note="Note: the worktree-gate.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to re-enable direct mode."
  jq -n --arg r "$1" --arg n "$note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ($r + (if $n != "" then " " + $n else "" end))
    }
  }'
  exit 0
}

# Prints the repo root when directory $1 is in a primary checkout that has at
# least one commit; returns 1 otherwise (including anything undeterminable).
primary_root() {
  local d="$1" sp top gd cdir n=0
  [ -d "$d" ] || return 1
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  # Submodule: judge the superproject instead (nested submodules too).
  while sp="$(git -C "$top" rev-parse --show-superproject-working-tree 2>/dev/null)" && [ -n "$sp" ]; do
    top="$sp"; n=$((n + 1)); [ "$n" -lt 5 ] || return 1
  done
  git -C "$top" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 1   # unborn
  gd="$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cdir="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cdir" in /*) ;; *) cdir="$top/$cdir" ;; esac
  gd="$(realpath -m -- "$gd" 2>/dev/null)" || return 1
  cdir="$(realpath -m -- "$cdir" 2>/dev/null)" || return 1
  [ -n "$gd" ] && [ "$gd" = "$cdir" ] || return 1
  printf '%s' "$top"
}

deny_message() {  # $1 = repo root, $2 = what was blocked
  local root="$1" branch
  branch="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  branch="${branch#origin/}"; [ -n "$branch" ] || branch=main
  deny "Worktree gate: $2 is in the primary checkout of $root. All work in a git repo happens in a linked worktree; do not edit, commit, switch branches or stash in the primary checkout. Create one with: git fetch origin && git worktree add -b <branch> ~/worktrees/<repo>-<slug> origin/$branch, then work there. Escape hatch: touch ~/.claude/worktree-gate.off (expires after 12 hours) or launch with CLAUDE_WORKTREE_GATE=off."
}

tool_name="$(jq -r '.tool_name // empty' <<<"$payload")"
command_str="$(jq -r '.tool_input.command // empty' <<<"$payload")"
cwd="$(jq -r '.cwd // empty' <<<"$payload")"

if [ "$tool_name" = "Bash" ] || [ -n "$command_str" ]; then
  [ -n "$command_str" ] || exit 0
  # Cheap prefilter: no `git` word, nothing to judge.
  printf '%s' "$command_str" | grep -qw git || exit 0
  command -v python3 >/dev/null 2>&1 || exit 0
  hits="$(CMD="$command_str" CWD="$cwd" GATE_HOME="$HOME" \
    python3 -B "$_gate_dir/_worktree-gate-check.py" 2>/dev/null)" || exit 0
  [ -n "$hits" ] || exit 0
  # `pull` is allowed on purpose (it is not in the scanner's list) so the
  # primary checkout's main can be fast-forwarded.
  while IFS=$'\t' read -r state dir sub; do
    [ -n "$dir" ] || continue
    if [ "$state" = "unknown" ]; then
      deny "Worktree gate: could not tell which checkout git $sub runs in ($dir), so it cannot be checked against the primary checkout. Write the directory literally, for example: git -C /absolute/path/of/the/worktree $sub ... or cd /absolute/path/of/the/worktree && git $sub ... (a directory made with mktemp -d on the same line is fine). Escape hatch: touch ~/.claude/worktree-gate.off (expires after 12 hours) or launch with CLAUDE_WORKTREE_GATE=off."
    elif root="$(primary_root "$dir")"; then
      deny_message "$root" "git $sub"
    fi
  done <<<"$hits"
  exit 0
fi

path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$payload")"
[ -n "$path" ] || exit 0
case "$path" in
  /*) ;;
  *) [ -n "$cwd" ] || exit 0; path="$cwd/$path" ;;
esac
# Resolve symlinks through the nearest existing ancestor; keep the missing tail.
existing="$path"; tail=""
while [ ! -e "$existing" ] && [ "$existing" != "/" ]; do
  tail="/$(basename "$existing")$tail"
  existing="$(dirname "$existing")"
done
real="$(realpath -- "$existing" 2>/dev/null)" || exit 0
full="$real$tail"
if [ -d "$real" ]; then dir="$real"; else dir="$(dirname "$real")"; fi
root="$(primary_root "$dir")" || exit 0
# Git-ignored paths are allowed (judged by the repo that directly contains them).
git -C "$dir" check-ignore -q -- "$full" 2>/dev/null && exit 0
deny_message "$root" "editing $full"
