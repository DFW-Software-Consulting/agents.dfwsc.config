#!/usr/bin/env bash
# PreToolUse gate: a pull request is merged only after the person typed the
# approval phrase for that exact pull request and head commit.
#   Phrase (a whole message, typed by the person):  merge OWNER/REPO#N <sha7+>
#   Valid 24 hours; a different head needs a new phrase; nothing is consumed by
#   a refused attempt, so an identical retry works (GitHub itself refuses a
#   second merge and, through --match-head-commit, a moved head).
#
# Bash: `gh pr merge` (any spelling the shared walker resolves, bash -c, eval,
# env, chains) must carry --repo OWNER/REPO, a numeric PR, exactly one of
# --merge/--squash/--rebase and --match-head-commit <40 hex>, and none of
# --admin, --auto, -d/--delete-branch; the phrase must be in the session
# transcript (hook input `transcript_path`) as a turn the person typed. Also
# denied: `gh api` calls to merge endpoints and GraphQL merge mutations, `gh alias
# set|import` and invoking a gh alias that merges, running a script file that
# holds merge text, and merge text on the line that the gate cannot judge as a
# plain command. If the transcript is missing, unreadable or in a format the
# gate does not recognise, a merge is denied (the person can run it with `!`).
# Edit/Write/NotebookEdit (and plainly named shell writes) to a Claude Code
# transcript, `*.jsonl` under a `projects/` folder of ~/.claude* , are denied.
# Applies to the main session AND subagents. Deny only: never answers allow or ask.
#
# Register on PreToolUse with matcher `Bash` and again with `Edit|Write|NotebookEdit`
# (one script, so the approval and the gate cannot be registered apart).
# Fails open on a bad payload. When jq or python3 is missing, or the checker
# cannot run or faults, it denies any command holding merge-related text (and any
# `gh pr` line holding a $ or a backtick) and allows the rest. A shell-side early
# exit skips python for a command with none of: merge, enqueue, alias, graphql,
# jsonl, gh, a shell or script word.
# A guard against honest mistakes and casual self-approval, not a barrier: see
# docs/context/hooks-overview.md for what it cannot see.
# The gate cannot be switched off by a tool call: writes to merge-gate.off and to
# this script and its checker under ~/.claude*/local-hooks are denied. Escape hatch: CLAUDE_MERGE_GATE=off, or touch
# ~/.claude/merge-gate.off (path overridable with CLAUDE_MERGE_GATE_OFF_FILE);
# the off-file expires after 12 hours (see _gate-common.sh). If _gate-common.sh is
# missing the gate stays ON.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
payload="$(cat)"

_gate_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
MG_OFF_FILE="${CLAUDE_MERGE_GATE_OFF_FILE:-$HOME/.claude/merge-gate.off}"
if source "$_gate_dir/_gate-common.sh" 2>/dev/null; then
  mg_off_state() { gate_off_file_state_for "$MG_OFF_FILE"; }
else
  mg_off_state() { echo none; }   # shared file unavailable: behave as gate ON
fi
[ "${CLAUDE_MERGE_GATE:-on}" = "off" ] && exit 0
off_state="$(mg_off_state)"
[ "$off_state" = "fresh" ] && exit 0
note=""
[ "$off_state" = "stale" ] && note="Note: the merge-gate.off escape hatch expired (older than 12 hours) and is being ignored; touch it again to re-enable."

# Without jq or python3 nothing can be parsed: deny merge-related text in the raw payload, allow the rest.
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  raw="$(printf '%s' "$payload" | sed -E 's/"(transcript_path|cwd|session_id)" *: *"[^"]*"//g')"   # path fields are not the command
  if printf '%s' "$raw" | grep -qiE 'merge|enqueue|alias|graphql|jsonl' \
     || printf '%s' "$raw" | grep -qiE 'gh.{0,60}pr.*[$`]'; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"merge-gate (tools-missing): jq or python3 is missing, so this command cannot be judged and it holds merge-related text. Install them, or the person can run the command with ! at the prompt."}}'
  fi
  exit 0
fi
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null)"
case "$tool" in
  Bash) command_str="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)"
        [ -n "$command_str" ] || exit 0
        # Shell-side early exit: none of these words, nothing to judge, no python started.
        printf '%s' "$command_str" | grep -qiE 'merge|enqueue|alias|graphql|jsonl|local-hooks|_gate-common|_cmd_dirs|_git-cmd-scan|_bash-write-check|\bgh\b|\b(bash|sh|zsh|dash|ksh|source|eval)\b|\.(sh|bash|zsh|py|mjs|js|rb|pl)\b|\./|(^|[;&|])[[:space:]]*\.[[:space:]]' || exit 0
        file_path="" ;;
  Edit|Write|NotebookEdit)
        command_str=""
        file_path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$payload" 2>/dev/null)"
        [ -n "$file_path" ] || exit 0
        printf '%s' "$file_path" | grep -qiE 'jsonl|merge-gate|local-hooks' || exit 0 ;;
  *) exit 0 ;;
esac

emit_deny() {  # RULE WHY
  jq -n --arg r "merge-gate ($1): $2 If JC explicitly asked for this exact action, he can run the command himself with ! at the prompt, or touch ~/.claude/merge-gate.off (valid 12 hours), or launch with CLAUDE_MERGE_GATE=off." --arg n "$note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ($r + (if $n != "" then " " + $n else "" end))
    }
  }'
}

cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)"
session="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)"
transcript="$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)"
hit="$(TOOL="$tool" CMD="$command_str" FILE_PATH="$file_path" CWD="$cwd" SESSION_ID="$session" \
  TRANSCRIPT="$transcript" GATE_HOME="$HOME" \
  python3 "$_gate_dir/_merge-gate-check.py" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  # The checker could not run at all (missing or broken file): fail closed on merge-looking text only.
  if printf '%s' "$command_str" | grep -qiE 'merge|enqueue|alias|graphql|jsonl|gh.{0,60}pr.*[$`]' || printf '%s' "$file_path" | grep -qiE 'jsonl|merge-gate'; then
    emit_deny "checker-failed" "the merge-gate checker could not run, so this command cannot be judged."
  fi
  exit 0
fi
[ -n "$hit" ] || exit 0
rule="${hit%%$'\t'*}"
why="${hit#*$'\t'}"
emit_deny "$rule" "$why"
exit 0
