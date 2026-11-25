#!/usr/bin/env bash
# PostToolUse hook (matcher Bash): warn-only reminder to run the brain-task-sync
# skill after a push or a new pull request. It never blocks, denies or asks.
# Nothing forces `git push` or `gh pr create` through the git-workflow agent, so
# when the main session or another agent pushes directly, the skill never runs.
#
# Acts only when the command that just ran contained a real `git push` (not
# --dry-run/-n, not --help, not --tags/--delete/--mirror/--all) or `gh pr create`
# (not --dry-run/--help), with no error signal in the hook input, and only when
# the command is about the CHECKED-OUT branch: a push naming another refspec, or
# a PR with another --head or --repo, stays silent. Calls from the git-workflow
# agent (payload agent_type) stay silent: it runs the skill itself. The directory
# comes from the shared walker (_cmd_dirs.py): literal `git -C`, `cd <dir> &&`
# (a relative path resolves against the payload cwd, assumed to be where the
# command started), `env -C`, bash -c bodies, else the payload cwd. It then reads
# the branch's saved Brain task and the repo's saved project from
# skills/brain-task-sync/brain-task.sh (local git config only) and adds one
# short line to the agent's context via hookSpecificOutput.additionalContext:
#   task saved      -> names the id; run brain-task-sync for the push|pr event
#   project saved   -> no task; run brain-task-sync in find mode, then the event
#   neither saved   -> silent, unless the origin owner is listed in
#                      ${CLAUDE_BRAIN_TASK_REMINDER_CONF:-~/.claude/brain-task-reminder.conf}
#                      key OWNERS (comma-separated GitHub owners, read as data)
# The wording never claims the push or PR worked: the input has no exit code, and
# a failure hidden in a pipeline or `|| echo` still reaches the hook as success.
# Error signals that do silence it: any event but PostToolUse, tool_response
# is_error/isError/error/interrupted. Never queries the database or the network;
# runs git config reads only; writes nothing (no bytecode either).
# Off: CLAUDE_BRAIN_TASK_REMINDER=off, or touch ~/.claude/brain-task-reminder.off
# (path overridable with CLAUDE_BRAIN_TASK_REMINDER_OFF_FILE); the off-file
# expires after 12 hours (see _gate-common.sh). If the off switch cannot be
# checked (HOME unset, _gate-common.sh missing) the hook stays silent. Fails
# open: any error means no output. Exit 0 always.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
IFS= read -r -d '' payload || true   # read first so an early exit never breaks the caller's pipe
[ "${CLAUDE_BRAIN_TASK_REMINDER:-on}" = "off" ] && exit 0
[ -n "${HOME:-}" ] || exit 0
[ -n "$payload" ] || exit 0

# Cheap prefilter on the raw payload (no process): `git` ... `push`, or `gh` ... `pr` ... `create`.
b='[^[:alnum:]_-]'
if ! [[ "$payload" =~ (^|[^[:alnum:]_.-])git$b.*[^[:alnum:]_-]?push($b|$) ]] \
   && ! [[ "$payload" =~ (^|[^[:alnum:]_.-])gh$b.*pr$b.*create($b|$) ]]; then exit 0; fi

command -v python3 >/dev/null 2>&1 || exit 0
_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || exit 0
source "$_dir/_gate-common.sh" 2>/dev/null || exit 0
[ "$(gate_off_file_state_for "${CLAUDE_BRAIN_TASK_REMINDER_OFF_FILE:-$HOME/.claude/brain-task-reminder.off}")" = "fresh" ] && exit 0
helper="$_dir/../skills/brain-task-sync/brain-task.sh"
[ -f "$helper" ] && [ -r "$_dir/_brain-task-reminder-check.py" ] || exit 0

hit="$(printf '%s' "$payload" | python3 -I -B "$_dir/_brain-task-reminder-check.py" 2>/dev/null)" || exit 0
[ -n "$hit" ] || exit 0
IFS=$'\t' read -r -a parts <<<"$hit"
event="${parts[0]:-}"; repo="${parts[1]:-}"
{ [ "$event" = push ] || [ "$event" = pr ]; } && [ -d "$repo" ] || exit 0

got="$(bash "$helper" "$repo" get 2>/dev/null)" || exit 0
grep -qx 'error=not-a-repo' <<<"$got" && exit 0
branch="$(sed -n 's/^branch=//p' <<<"$got" | head -1)"
[ -n "$branch" ] || exit 0   # detached HEAD or unreadable

# Only the checked-out branch counts.
if [ "$event" = push ]; then
  for f in "${parts[@]:2}"; do
    r="${f#r=}"; r="${r#+}"
    [ -n "$r" ] || exit 0
    src="$r"; dst="$r"
    if [[ "$r" == *:* ]]; then src="${r%%:*}"; dst="${r#*:}"; fi
    [ -n "$src" ] && [ -n "$dst" ] || exit 0
    dst="${dst#refs/heads/}"; src="${src#refs/heads/}"
    [ "$dst" = "$branch" ] || { [ "$dst" = HEAD ] && [ "$src" = HEAD ]; } || exit 0
    [ "$src" = HEAD ] || [ "$src" = "$branch" ] || exit 0
  done
else
  head="${parts[2]:-}"; head="${head#h=}"; prrepo="${parts[3]:-}"; prrepo="${prrepo#R=}"
  [ -z "$head" ] || [ "$head" = "$branch" ] || exit 0
fi

url="$(git -C "$repo" config --local --get remote.origin.url 2>/dev/null)"
oown=""; orepo=""
if [[ "$url" =~ ^(git@|ssh://git@|https?://)github\.com[:/]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+) ]]; then
  oown="${BASH_REMATCH[2],,}"; orepo="${BASH_REMATCH[3]%.git}"; orepo="${orepo,,}"
fi
if [ "$event" = pr ] && [ -n "$prrepo" ]; then
  [ -n "$oown" ] && [ "${prrepo,,}" = "$oown/$orepo" ] || exit 0
fi

task="$(sed -n 's/^task=//p' <<<"$got" | head -1)"; task="${task%% *}"; task="${task,,}"
if [ "$task" = none ] || ! [[ "$task" =~ ^([1-9][0-9]{0,6}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$ ]]; then task=""; fi

if [[ "$branch" =~ ^[A-Za-z0-9._/-]{1,100}$ ]]; then where="$branch"; else where="this branch"; fi
if [ "$event" = push ]; then what="A push command ran on $where"; else what="A PR create command ran on $where"; fi
if [ -n "$task" ]; then
  msg="$what. This branch is on Brain task $task. If it went through and brain-task-sync has not already run for it, run it now (event $event) so the task gets its progress note. It never blocks."
else
  find=0
  proj="$(bash "$helper" "$repo" project get 2>/dev/null | sed -n 's/^project=//p' | head -1)"
  [[ "$proj" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && find=1
  if [ "$find" -eq 0 ]; then
    conf="${CLAUDE_BRAIN_TASK_REMINDER_CONF:-$HOME/.claude/brain-task-reminder.conf}"
    if [ -f "$conf" ] && [ -r "$conf" ] && [ -n "$oown" ]; then
      owners="$(grep -m1 '^OWNERS=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
      IFS=',' read -r -a list <<<"${owners,,}"
      for o in "${list[@]}"; do
        o="${o#"${o%%[![:space:]]*}"}"; o="${o%"${o##*[![:space:]]}"}"
        [ -n "$o" ] && [ "$o" = "$oown" ] && find=1
      done
    fi
  fi
  [ "$find" -eq 1 ] || exit 0
  msg="$what. No Brain task is saved for this branch. If it went through and brain-task-sync has not already run for it, run it in find mode to look for one, then the $event event. It never blocks."
fi

# msg holds only fixed text, a validated branch and a validated task id: no JSON escaping needed.
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$msg"
exit 0
