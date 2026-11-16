# Error log

Newest first. Check here before proposing a fix.

## A listing of hook commands shows `null || true`
- Cause: a listing that prints the last path segment of each hook command shows `null || true` for a command ending in `2>/dev/null || true`. The hook is still registered; only the display is misleading.
- Fix: read the full command string instead of its last path segment.
- Date: 2026-11-15

## Capturing a check's output through a pipe hangs
- Cause: reading a command's output through a pipe blocks while a backgrounded child holds the pipe open, and buffers all output in memory.
- Fix: write the output to a temporary file, wait only for the command's shell, then terminate its process group.
- Date: 2026-11-15

## git long option abbreviations not denied (`--force-w`, `--no-ver`)
- Cause: git long options were matched by exact string, so abbreviations that git accepts were missed.
- Fix: match unambiguous prefixes against an explicit option list.
- Date: 2026-11-15

## Command header with `Task(subagent:name)` or `View` pre-approves nothing
- Cause: the subagent tool is named `Agent`, one subagent is `Agent(name)`, and reading is `Read`. `allowed-tools` pre-approves tools rather than restricting them, so wrong names are silently ineffective.
- Fix: use `Agent`, `Agent(name)` and `Read` in `allowed-tools`.
- Date: 2026-11-15

## `stat` size check passed a symlink to a large file
- Cause: `stat` on a symlink reports the link's own size.
- Fix: resolve the path before measuring.
- Date: 2026-11-15

## `--format='a > b'` read as a redirect
- Cause: tokenising shell with shlex in non-posix mode does not treat a quote that starts mid-word as a quote.
- Fix: a hand-written quote-aware scanner.
- Date: 2026-11-15

## Fenced code blocks not stripped by a jq regex
- Cause: the regex used flags "sg", which does not make `.` match newlines, so blocks were never stripped.
- Fix: flags "gp".
- Date: 2026-11-15

## Stacked pull request needs rebase and force push after squash merge
- Cause: squash-merging the base of a stacked pull request leaves the stacked branch needing a rebase and a force push.
- Fix: merge the stacked request into its base first, or do not stack.
- Date: 2026-11-15

## exit 2, got allow (15 tests fail when only local-hooks/ is exported)
- Cause: exporting only `local-hooks/` to test a merged main; one suite calls `../hooks/no-agent-mention.py`.
- Fix: export or check out both `local-hooks/` and `hooks/`.
- Date: 2026-11-15
