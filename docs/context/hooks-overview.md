# Hook scripts

Scripts live in `ai-code-agents/claude/local-hooks/` (tracked, tested), `ai-code-agents/claude/hooks/` and `ai-code-agents/claude/personal-hooks/`. The repository does not register any of them except where noted; "event" is where a script is meant to be registered. Each script's header comment is the detailed spec.

## Scripts
| Script | Event, matcher | Enforces | Off switch |
|---|---|---|---|
| delegate-gate.sh | PreToolUse, Edit/Write/NotebookEdit (and Bash) | Main session may not edit files; on Bash denies redirects to files, tee, `sed -i`, `perl -i`, `awk -i inplace`. Subagents unaffected | CLAUDE_DELEGATE_GATE=off or 12h off-file |
| delegate-reminder.sh | UserPromptSubmit | One-line delegation reminder | same as delegate-gate |
| require-agent-model.sh | PreToolUse, Agent/Task | Every subagent call sets `model` (forks exempt) | same as delegate-gate |
| read-size-gate.sh | PreToolUse, Read | Main session may not read a text file over 300 lines or 30000 bytes without a limit of 300 or less | same as delegate-gate; CLAUDE_READ_GATE_MAX_LINES / _MAX_BYTES change limits |
| worktree-gate.sh | PreToolUse, Edit/Write/NotebookEdit and Bash | No edits or HEAD/index/worktree-changing git commands in a primary checkout | CLAUDE_WORKTREE_GATE=off or 12h off-file |
| git-guard.sh | PreToolUse, Bash | No hook bypass (`--no-verify`, `commit -n`, `HUSKY=0`, core.hooksPath), no force push, no push to the default branch | CLAUDE_GIT_GUARD=off or 12h off-file |
| public-repo-text-gate.sh | PreToolUse, Bash | On public repos, no private hostnames, IPs, emails or configured terms in commit, tag, and gh pr/issue text | CLAUDE_PUBLIC_TEXT_GATE=off |
| shared-db-write-gate.sh | PreToolUse, MCP tools ending execute_sql or apply_migration | Ownership, project lookup, generated-column and no-schema-change rules for writes to a shared database | CLAUDE_SHARED_DB_GATE=off; inactive without its config file |
| require-acceptance-criteria.sh | PreToolUse, Agent | Brief to a non-exempt subagent has a "Done when" style section | CLAUDE_ACCEPTANCE_GATE=off |
| handback-gate.sh | PreToolUse SubagentHandback, and SubagentStop | Report has an Acceptance check section with no "not met" line and a `Context docs:` line; at most 4000 characters; two send-backs then passes | CLAUDE_ACCEPTANCE_GATE=off (acceptance part); CLAUDE_HANDBACK_MAX_CHARS sets the cap |
| context-docs-start.sh | SessionStart, SubagentStart | Injects `docs/context/INDEX.md` (first 3000 characters) plus standing subagent instructions | CLAUDE_ACCEPTANCE_GATE=off drops the acceptance line |
| enforce-response-cap.sh | Stop | Nags once when a reply exceeds 1200 characters outside code blocks | approval via reply-cap-prompt.sh |
| reply-cap-prompt.sh | UserPromptSubmit | States the cap; records long-reply approvals ("go long", "limit off", ...) | "limit off" / "limit on" phrases |
| clock-reminder.sh | SessionStart, UserPromptSubmit | Reminders by local time from a local config file, once per day each | no config file means no output |
| behavior-doc-reminder.sh | PreToolUse and PostToolUse (mode argument `pre` or `post`), Bash | Warn-only nudge to document behavior changes around commit, push, PR create | warn-only |
| ../hooks/no-agent-mention.py | PreToolUse, Bash (registered in the repo's settings.json) | Denies commits and `gh pr` text that credit a coding agent | none |
| ../personal-hooks/sync-memory.sh | SessionStart | Keeps per-project memory folders of two config dirs symlinked | none |

The 12h off-file: a file whose modification time is under 12 hours old; a stale one is ignored, not deleted. Default paths are under `~/.claude/` and can be overridden by an environment variable named in the script.

## Shared libraries
- `_gate-common.sh`: off switch and off-file expiry. Used by delegate-gate, delegate-reminder, require-agent-model, read-size-gate, worktree-gate, git-guard. If it is missing, gates stay on.
- `_handback-common.sh`: exempt agent types, send-back cap, report length cap, acceptance switch. Used by context-docs-start, require-acceptance-criteria, handback-gate.
- `_reply-cap-common.sh`: reply cap, approval phrases, marker paths. Used by enforce-response-cap, reply-cap-prompt.
- `_bash-write-check.py`: quote-aware file-write finder for delegate-gate.
- `_git-cmd-scan.py`: quote-aware git command scanner with cwd tracking (`cd`, `-C`). Used by worktree-gate; loaded by `_git-guard-check.py` and `_public-text-check.py`.
- `_git-guard-check.py` (git-guard), `_public-text-check.py` (public-repo-text-gate), `_sql-write-check.py` (shared-db-write-gate): the parsing and decision logic for those gates.
- Config examples: `shared-db-gate.conf.example`, `public-text-gate.conf.example`, `clock-reminders.conf.example`.

## Design rules
- Fail open: malformed input, a missing tool (jq, python3, git) or an undeterminable state exits 0 with no output. The exception is a missing `_gate-common.sh`, where the gate stays on.
- Deny output is built with a JSON encoder (jq or Python), never by string concatenation.
- Hooks never modify a repository; git is only queried.
- Environment-specific values (project references, person ids, terms, reminder text) live in local config files outside this repo, parsed as data and never sourced. Only `*.conf.example` files with fake values are committed.
- Gates apply to the main session and subagents unless the header says otherwise.
- Known limits are listed in each script's PR; for example `bash -c` bodies and git aliases are not parsed.
