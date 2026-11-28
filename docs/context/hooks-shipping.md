# Shipping a hook change

This repo is designed so that a long-lived main worktree serves the live scripts (for example through a `~/.claude/local-hooks` link). That setup is a convention; the repo cannot confirm it for your machine. Find the worktree with `git worktree list`: it is the one checked out on `main`. Settings files and local config files are not in this repository.

## How live configuration is served
Since 2026-11-17 hooks, skills, agents and commands, in both Claude configuration directories, are whole-directory links into the long-lived main worktree. The primary checkout is not what sessions read. Every change therefore ships the same way: worktree off main, tests, pull request, merge, fast-forward the main worktree. Two local prerequisites of that arrangement (neither is in the repo):
- A helper link beside the main worktree, for the skills committed as relative links to a sibling skills repository.
- A copy of the gitignored runtime `synced` folder inside the main worktree's skills directory.
Two skills are committed as absolute links and still resolve through the primary checkout; fix those in the repo before relying on them from the main worktree. Check what a link serves with `readlink -f` before assuming a merged change is live (see errors.md).

## Steps
1. Create a branch in a new worktree off the default branch, running git through the long-lived main worktree, not the primary checkout:
   `git -C <main worktree> fetch origin && git -C <main worktree> worktree add -b <branch> <new worktree path> origin/main`
2. Edit and test in the new worktree only (see hooks-testing.md). All suites must report 0 failed.
3. Before pushing a long-lived local branch, run `git status -sb` and `git log origin/<branch>..HEAD` and scan the unpushed diff for identifiers (see errors.md). Open a pull request; to edit it later use `gh api -X PATCH repos/<owner>/<name>/pulls/<n>`, since `gh pr edit` fails here. Describe behavior, testing, known limits and how to switch it on. Text on this public repo must contain no hostnames, addresses, emails or machine names.
4. Merge (a sub-session in auto mode may be refused `gh pr merge`; the person or the main session runs it, with `--match-head-commit`). Do not stack a pull request on an unmerged branch (see errors.md).
5. Fast-forward the main worktree (`git -C <main worktree> pull --ff-only`) so what it serves picks up the merge.
6. NEW hook only (skills, agents and commands need no registration): register it in each settings file your tool configuration uses (there can be more than one configuration directory) with the event and matcher from its header comment (see hooks-overview.md). A changed existing hook needs no registration.
7. If it needs a local config file, create one from the `*.conf.example`, outside the repo.
8. Remove the worktree with `git worktree remove` after the merge.

## Registering merge-gate.sh (owner step, outside the repo)
One script, two matchers, in each settings file your tool configuration uses (`~/.claude/settings.json` and `~/.claude-personal/settings.json`). Under `hooks.PreToolUse` add to the `Bash` matcher's hooks list, and add an `Edit|Write|NotebookEdit` matcher entry (the second is the transcript and switch tripwire):
```json
{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.claude/local-hooks/merge-gate.sh"}]},
{"matcher": "Edit|Write|NotebookEdit", "hooks": [{"type": "command", "command": "bash ~/.claude/local-hooks/merge-gate.sh"}]}
```
Register both together: until the gate is registered nothing changes, and once it is registered a merge by an agent needs the typed phrase `merge OWNER/REPO#N <sha7+>` (or the person runs the merge with `!`).

What it is: a guard against honest mistakes and casual self-approval, not a barrier. It stops: a `gh pr merge` without the pinned flags and a typed approval for that head; `gh api` merge endpoints and GraphQL merge mutations; `gh alias set|import` and aliases that merge; scripts holding merge text; dynamic words in the gh subcommand position; a redirected gh config; plainly visible writes to transcripts, to `merge-gate.off` and to the gate's own files. It does not stop: interpreters (python and the like) calling gh or forging a transcript line or editing the off-file, make/npm/yarn/pnpm scripts, scripts named through variables or globs, curl with a variable path, gh extensions, a gh binary copied or symlinked under another name, commands built from printf escapes or concatenated variables that contain none of the early-exit words, git aliases read from config files, upper-case command names on a case-insensitive filesystem, writes to protected files through variables, globs or interpreters, `!` merges, the web UI. A Claude Code release that changes the transcript record fields makes every merge deny until `_merge-gate-check.py` is updated. Running a script that holds merge text through the Bash tool is denied. It also unwraps `eval`/`bash -c` of a variable assigned on the same line and the common wrappers (`find -exec`, `xargs`, `watch`, `script -c`, `flock`, `busybox`, `strace`, `ssh`, `parallel`, `fish -c`), and protects the files the gate loads (`_gate-common.sh`, `_cmd_dirs.py`, `_git-cmd-scan.py`, `_bash-write-check.py`) like the gate itself. Maintainers can run `tests/run-merge-gate-tests.sh` and `_merge-gate-check.py` (exempt by path). Ordinary work is not blocked: merge text inside commit messages, PR bodies, `echo`, `grep`, `man` and file checks is allowed. The gate cannot be switched off by a tool call (writes to the off-file or the gate files are denied): the person uses `!touch ~/.claude/merge-gate.off` (valid 12 hours) or `CLAUDE_MERGE_GATE=off`.

## Adding a new hook: checklist
- Header comment stating the event, the matcher, what it enforces and the off switch if it has one (a couple of older scripts, such as delegate-reminder.sh and clock-reminder.sh, predate this).
- Fails open on malformed input and missing tools; deny output built with jq or Python.
- An environment off switch. A gate that enforces a workflow rule a person may deliberately need to step around also honours a 12-hour off-file through `_gate-common.sh`; today those are delegate-gate, require-agent-model, read-size-gate, worktree-gate, git-guard, merge-gate, public-repo-text-gate, shared-db-write-gate, require-acceptance-criteria, handback-gate (the last two share one acceptance off-file) and completion-gate.
- A `tests/run-<name>-tests.sh` suite beside the others, with allow and deny payloads, using a throwaway HOME and no network.
- Environment-specific values in a local config file read as data, with a fake-valued `*.conf.example` committed.
- Add it to hooks-overview.md and hooks-testing.md.
