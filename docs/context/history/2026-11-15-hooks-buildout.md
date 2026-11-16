# Hooks buildout, pull requests 10 to 21
Date: 2026-11-15
Scope: what pull requests 10 to 21 added or changed.
Findings:
- #10 Tracks six existing hook scripts (delegate gate and reminder, agent-model gate, response cap, behavior-doc reminder, memory sync) under `local-hooks/` and `personal-hooks/`, copied unchanged.
- #11 delegate-gate also covers Bash file writes via `_bash-write-check.py`; off-file expires after 12 hours via `_gate-common.sh`; no-agent-mention also checks `gh pr` text.
- #12 Adds context-docs-start, require-acceptance-criteria and handback-gate, plus the context-docs skill.
- #13 Adds worktree-gate: no edits or HEAD-changing git commands in a primary checkout.
- #14 Adds shared-db-write-gate with `_sql-write-check.py`; configuration is a local file outside the repo.
- #15 Adds read-size-gate (reads over 300 lines or 30000 bytes) and clock-reminder (config-driven reminders once per day).
- #16 Reply cap now measured from the stop payload; adds reply-cap-prompt for long-reply approval; handback-gate caps reports at 4000 characters.
- #17 Adds public-repo-text-gate: infrastructure details in commit, tag and gh text on public repos.
- #18 Removes stale README references and dead files; `/ce:cm` saves its handoff summary and uses existing tool names.
- #19 Retires duplicate commands and skills; fixes tool-list headers (`Agent(name)`, `Agent`, `Read`).
- #20 Adds `Write` to the `/smallwins` header.
- #21 Adds git-guard (no hook bypass, no force push, no push to the default branch) and refactors `_git-cmd-scan.py` onto a `walk()` generator; old and new output matched on 460 combinations.
Lessons:
- Test the whole `ai-code-agents/claude/` tree, not just `local-hooks/`.
- Do not stack pull requests on a base that will be squash-merged.
- Write a quote-aware scanner for shell text; shlex non-posix mode and regexes misread quotes.
- Resolve symlinks before measuring or judging a path.
- Match git long options by unambiguous prefix, as git does.
- When a shared scanner changes, compare old and new output on the same inputs.
- Capture command output through a temporary file, not a pipe.
- Verify tool names in command headers; wrong names pre-approve nothing.
