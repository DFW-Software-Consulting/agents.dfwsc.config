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

## Adding a new hook: checklist
- Header comment stating the event, the matcher, what it enforces and the off switch if it has one (a couple of older scripts, such as delegate-reminder.sh and clock-reminder.sh, predate this).
- Fails open on malformed input and missing tools; deny output built with jq or Python.
- An environment off switch. A gate that enforces a workflow rule a person may deliberately need to step around also honours a 12-hour off-file through `_gate-common.sh`; today those are delegate-gate, require-agent-model, read-size-gate, worktree-gate, git-guard, public-repo-text-gate, shared-db-write-gate, require-acceptance-criteria, handback-gate (the last two share one acceptance off-file) and completion-gate.
- A `tests/run-<name>-tests.sh` suite beside the others, with allow and deny payloads, using a throwaway HOME and no network.
- Environment-specific values in a local config file read as data, with a fake-valued `*.conf.example` committed.
- Add it to hooks-overview.md and hooks-testing.md.

## Registering handoff-pointer.sh (not registered by its change)
Safe order: merge and update the live checkout first; create the conf from `handoff-pointer.conf.example`; pipe a sample payload to the live script and check the output; only then add, identically in every settings file, a `SessionStart` group with matcher `startup|clear`, a command of the form `bash <path to the hook> 2>/dev/null || true` and a 5 second timeout; then start one session in a repository and one in the home directory.
