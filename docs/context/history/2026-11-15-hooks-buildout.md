# Hooks buildout, pull requests 10 to 23
Date: 2026-11-15
Scope: what pull requests 10 to 23 added or changed.
Findings:
- #10 Tracks six existing hook scripts (delegate gate and reminder, agent-model gate, response cap, behavior-doc reminder, memory sync) under `local-hooks/` and `personal-hooks/`, copied unchanged.
- #11 delegate-gate also covers Bash file writes via `_bash-write-check.py`; off-file expires after 12 hours via `_gate-common.sh`; no-agent-mention also checks `gh pr` text.
- #12 Adds context-docs-start, require-acceptance-criteria and handback-gate, plus the context-docs skill.
- #13 Adds worktree-gate: no edits or HEAD-changing git commands in a primary checkout.
- #14 Adds shared-db-write-gate with `_sql-write-check.py`; configuration is a local file outside the repo.
- #15 Adds read-size-gate (reads over 300 lines or 30000 bytes) and clock-reminder (config-driven reminders once per day).
- #16 Reply cap measured from the stop payload; adds reply-cap-prompt for long-reply approval; handback-gate caps reports at 4000 characters.
- #17 Adds public-repo-text-gate: infrastructure details in commit, tag and gh text on public repos.
- #18 Removes stale README references and dead files; `/ce:cm` saves its handoff summary and uses existing tool names.
- #19 Retires duplicate commands and skills; fixes tool-list headers (`Agent(name)`, `Agent`, `Read`).
- #20 Adds `Write` to the `/smallwins` header.
- #21 Adds git-guard (no hook bypass, no force push, no push to the default branch); refactors `_git-cmd-scan.py` onto a `walk()` generator, old and new output matched on 460 combinations.
- #22 Adds `run-checks.sh`, `_run_checks.py`, `_checks_stamp.py` and the `git-verify` skill: runs a repo's checks for the current commit and writes a stamp keyed by commit hash. On request only; not a hook. Refused on a dirty tree; a would-be pass becomes dirty_after if HEAD moved.
- #23 Reply cap: adds "explain this more", "explain that more", "explain more", "tell me more", "elaborate" as one-shot approvals; a one-shot phrase no longer ends a session-long "limit off" approval.
- Adds checks-gate (reads the run-checks stamps before push and PR create; warn or deny by config) and conditional `--force-with-lease` in git-guard (valid stamp, then ask).
- Off-file for public-repo-text-gate, shared-db-write-gate and the acceptance pair (require-acceptance-criteria, handback-gate, context-docs-start): a fresh `~/.claude/public-text-gate.off`, `shared-db-gate.off` or `acceptance-gate.off` switches the gate off for 12 hours; a stale or future-dated one is ignored with an "expired" note in the denial text; environment switches unchanged.
- Branch feat/split-git-workflow-skills (not a numbered pull request): splits the git-workflow skill into git-commit, git-push, git-pr and git-issue beside git-verify, adds `git-facts.sh` and its suite, turns the agent into a router and the old skill into a stub; drops the PR template's AI usage section.
Lessons:
- Test the whole `ai-code-agents/claude/` tree, not just `local-hooks/`.
- Do not stack pull requests on a base that will be squash-merged.
- Write a quote-aware scanner for shell text; shlex non-posix mode and regexes misread quotes.
- Resolve symlinks before measuring or judging a path.
- Match git long options by unambiguous prefix, as git does.
- When a shared scanner changes, compare old and new output on the same inputs.
- Capture command output through a temporary file, not a pipe.
- Verify tool names in command headers; wrong names pre-approve nothing.
- A hook decision of "ask" is soft: keep judging the rest of the command line before answering.
