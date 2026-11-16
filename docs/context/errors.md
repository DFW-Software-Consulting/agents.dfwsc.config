# Error log

Newest first. Check here before proposing a fix.

## `null || true` in a listing of hook commands
- Cause: in a listing that prints the last path segment of each hook command, a command ending in `2>/dev/null || true` shows as `null || true`. The hook is still registered; only the display misleads.
- Fix: read the full command string, not its last path segment.
- Date: 2026-11-15

## Output capture from a check hangs (run-checks.sh, `_run_checks.py`)
- Cause: reading a command's output through a pipe blocks while a backgrounded child holds the pipe open, and buffers all output in memory.
- Fix: write the output to a temporary file, wait only for the command's shell, then terminate its process group.
- Date: 2026-11-15

## `--force-w` or `--no-ver` not denied (git-guard.sh, `_git-guard-check.py`)
- Cause: git long options were matched by exact string, so abbreviations that git accepts were missed.
- Fix: match unambiguous prefixes against an explicit option list.
- Date: 2026-11-15

## `Task(subagent:name)` or `View` in a command's `allowed-tools` pre-approves nothing
- Cause: the subagent tool is named `Agent`, one subagent is `Agent(name)`, reading is `Read`. `allowed-tools` pre-approves tools rather than restricting them, so wrong names are silently ineffective. Affects files under `ai-code-agents/claude/commands/`.
- Fix: use `Agent`, `Agent(name)` and `Read`.
- Date: 2026-11-15

## Large file passes the size check through a symlink (read-size-gate.sh)
- Cause: `stat` on a symlink reports the link's own size.
- Fix: resolve the path first.
- Date: 2026-11-15

## `--format='a > b'` read as a redirect (`_bash-write-check.py`, `_git-cmd-scan.py`)
- Cause: tokenising shell with shlex in non-posix mode does not treat a quote that starts mid-word as a quote.
- Fix: a hand-written quote-aware scanner.
- Date: 2026-11-15

## Fenced code blocks still counted toward the reply cap (enforce-response-cap.sh)
- Cause: a jq regex meant to strip fenced code blocks used flags "sg", which does not make `.` match newlines, so blocks were never stripped.
- Fix: flags "gp".
- Date: 2026-11-15

## Stacked pull request needs a rebase and a force push
- Cause: squash-merging the base of a stacked pull request leaves the stacked branch needing a rebase and a force push.
- Fix: merge the stacked request into its base first, or do not stack.
- Date: 2026-11-15

## `exit 2, got allow` (15 tests fail in run-tests.sh)
- Cause: only `local-hooks/` was exported to test a merged main; `run-tests.sh` calls `../hooks/no-agent-mention.py`.
- Fix: export or check out both `local-hooks/` and `hooks/`.
- Date: 2026-11-15
