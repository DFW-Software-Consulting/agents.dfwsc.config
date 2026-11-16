# Hook scripts

This repository only tracks the scripts. Which of them are registered is decided by settings files outside the repository (the repo's `ai-code-agents/claude/settings.json` registers only `no-agent-mention.py`), so you cannot tell from the repo which hooks are active: check your own settings. "Event" below is where a script is meant to be registered, from its header comment, which is the detailed spec.

Scripts live in `ai-code-agents/claude/local-hooks/`, `hooks/` and `personal-hooks/`.

## Scripts
| Script | Event, matcher | What it does | Off switch |
|---|---|---|---|
| delegate-gate.sh | PreToolUse, Edit/Write/NotebookEdit (and Bash) | Denies file edits from the main session; on Bash denies redirects to files, tee, `sed -i`, `perl -i`, `awk -i inplace`. Subagents unaffected | CLAUDE_DELEGATE_GATE=off or 12h off-file |
| delegate-reminder.sh | UserPromptSubmit | One-line delegation reminder | same |
| require-agent-model.sh | PreToolUse, Agent/Task | Denies a subagent call without `model` (forks exempt) | same |
| read-size-gate.sh | PreToolUse, Read | Main session: denies text files over 300 lines or 30000 bytes without a limit of 300 or less | same; CLAUDE_READ_GATE_MAX_LINES / _MAX_BYTES change limits |
| worktree-gate.sh | PreToolUse, Edit/Write/NotebookEdit and Bash | Denies edits and HEAD/index/worktree-changing git commands in a primary checkout | CLAUDE_WORKTREE_GATE=off or 12h off-file |
| git-guard.sh | PreToolUse, Bash | Denies hook bypass (`--no-verify`, `commit -n`, `HUSKY=0`, core.hooksPath), force push, push to the default branch. A lease-only force push (`--force-with-lease`, `--force-if-includes`) is denied unless HEAD has a valid check stamp, then it answers "ask"; an ask never stops the rest of the line being judged. Stamps are unsigned: a guardrail, not a seal | CLAUDE_GIT_GUARD=off or 12h off-file |
| checks-gate.sh | PreToolUse, Bash | Before `git push` and `gh pr create`, wants a valid check stamp for HEAD; warns (default) or denies by `~/.claude/checks-gate.conf` (`MODE`, `DENY_AFTER`). Silent when the repo has no checks or the branch since its merge base with the default branch is docs only; a broken check configuration counts as no record. Skips dry-run, delete, tags-only, other refs, `gh pr create --repo`. Read-only | CLAUDE_CHECKS_GATE=off |
| public-repo-text-gate.sh | PreToolUse, Bash | On public repos denies private hostnames, IPs, emails, configured terms in commit, tag and gh pr/issue text | CLAUDE_PUBLIC_TEXT_GATE=off |
| shared-db-write-gate.sh | PreToolUse, MCP tools ending execute_sql or apply_migration | Ownership, project-lookup, generated-column and no-schema-change rules for writes to a shared database | CLAUDE_SHARED_DB_GATE=off; inactive without its config file |
| require-acceptance-criteria.sh | PreToolUse, Agent | Main-session calls only (returns early when the payload has an agent id): denies a brief to a non-exempt subagent type with no "Done when" style section | CLAUDE_ACCEPTANCE_GATE=off |
| handback-gate.sh | PreToolUse SubagentHandback, and SubagentStop | Sends back a report lacking an Acceptance check section, containing a "not met" line, lacking a `Context docs:` line, or over 4000 characters; two send-backs, then it passes | CLAUDE_ACCEPTANCE_GATE=off disables all of these checks together, including the size limit (it exits before the size check) |
| context-docs-start.sh | SessionStart, SubagentStart | Injects the first 3000 characters of `docs/context/INDEX.md`, plus standing subagent instructions | CLAUDE_ACCEPTANCE_GATE=off drops the acceptance instruction |
| enforce-response-cap.sh | Stop | Nags once when a reply exceeds 1200 characters outside code blocks | an approval recorded by reply-cap-prompt.sh |
| reply-cap-prompt.sh | UserPromptSubmit | States the cap; records approvals for a long reply ("go long", "tell me more", "elaborate", ...; "limit off" until "limit on") | the approval phrases |
| clock-reminder.sh | SessionStart, UserPromptSubmit | Reminders by local time from a local config file, once per day each | no config file means no output |
| behavior-doc-reminder.sh | PreToolUse and PostToolUse on Bash; first argument `pre` or `post` | Warn-only nudge to document behavior changes around commit, push and PR create | none |
| ../hooks/no-agent-mention.py | PreToolUse, Bash | Denies commits and `gh pr` text that credit a coding agent | none |
| ../personal-hooks/sync-memory.sh | SessionStart | Keeps per-project memory folders of two config dirs symlinked | none |

The 12h off-file: a file under `~/.claude/` (path overridable by an environment variable named in the script) whose modification time is under 12 hours old; a stale one is ignored, not deleted.

## Not a hook: run-checks
`run-checks.sh` (logic in `_run_checks.py`) runs a repo's checks for the current commit and writes a stamp file in the worktree's git dir. It is run on request by the `git-verify` skill (`skills/git-verify/SKILL.md`), never from a hook. `_checks_stamp.py` defines check detection and the stamp; it is used by `_run_checks.py` (writes) and, through `_git-guard-check.py`'s `stamp_info`, by git-guard's lease rule and checks-gate (read). Checks come from a `.claude/git-checks` file at the repository root, else the `typecheck`, `lint` and `test` scripts in package.json. `CLAUDE_CHECKS_TIMEOUT` sets seconds per command.

## Libraries
- `_gate-common.sh`: off switch and off-file expiry. Sourced by delegate-gate, delegate-reminder, require-agent-model, read-size-gate, worktree-gate, git-guard. If missing, gates stay on.
- `_handback-common.sh`: exempt agent types, send-back cap, report cap, acceptance switch. Sourced by context-docs-start, require-acceptance-criteria, handback-gate.
- `_reply-cap-common.sh`: cap, approval phrases, marker paths. Sourced by enforce-response-cap, reply-cap-prompt.
- `_bash-write-check.py`: quote-aware write finder for delegate-gate; its tokenizer is also loaded by `_git-cmd-scan.py`.
- `_git-cmd-scan.py`: git command scanner with cwd tracking. Run by worktree-gate; loaded by `_git-guard-check.py` and `_public-text-check.py`.
- `_public-text-check.py` also imports its text extraction from `../hooks/no-agent-mention.py`.
- `_checks-gate-check.py` (checks-gate): decision logic; imports `_git-guard-check.py` and `_public-text-check.py` (an import failure disables the gate). `checks-gate.conf.example` is its config example.
- `_git-guard-check.py` (git-guard), `_public-text-check.py` (public-repo-text-gate), `_sql-write-check.py` (shared-db-write-gate): decision logic.
- Config examples: `shared-db-gate.conf.example`, `public-text-gate.conf.example`, `clock-reminders.conf.example`, `checks-gate.conf.example`.

## Payload fields the scripts read
`hook_event_name`, `cwd`, `tool_name`, `tool_input.command`, `tool_input.file_path`, `tool_input.notebook_path`, `tool_input.limit`, `tool_input.pages`, `tool_input.model`, `tool_input.subagent_type`, `tool_input.prompt`, `tool_input.message`, `agent_id` (present only on subagent calls; the gates use it to tell subagent from main session), `agent_type`, `prompt`, `last_assistant_message`, `stop_hook_active`, `session_id`, `transcript_path`, `scratchpad_dir`.

## Runtime dependencies
- bash everywhere; jq for nearly every script (missing jq means allow, except sync-memory).
- python3 for the Bash-parsing paths: delegate-gate (Bash), worktree-gate, git-guard, checks-gate, public-repo-text-gate, shared-db-write-gate, run-checks.
- git: worktree-gate, git-guard, checks-gate, context-docs-start, behavior-doc-reminder, run-checks. gh: optional visibility lookup in public-repo-text-gate.

## Design rules (the gate scripts)
- Fail open: malformed input, a missing tool or an undeterminable state exits 0 with no output (a missing `_gate-common.sh` keeps the gate on).
- Deny output is built with a JSON encoder, not string concatenation.
- Gates never modify a repository; git is only queried.
- Environment-specific values live in local config files outside the repo, parsed as data and never sourced; only fake-valued `*.conf.example` files are committed.
- Exceptions: `sync-memory.sh` uses `set -euo pipefail` and exits non-zero without jq. `behavior-doc-reminder.sh` exits 1 when run without its mode argument and keeps a state file under `/tmp`. Some denial and reminder texts are written for one specific user.
