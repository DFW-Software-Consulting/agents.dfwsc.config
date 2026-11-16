# Shipping a hook change

This repo is designed so that a long-lived main worktree serves the live scripts (for example through a `~/.claude/local-hooks` link). That setup is a convention; the repo cannot confirm it for your machine. Find the worktree with `git worktree list`: it is the one checked out on `main`. Settings files and local config files are not in this repository.

## Steps
1. Create a branch in a new worktree off the default branch, running git through the long-lived main worktree, not the primary checkout:
   `git -C <main worktree> fetch origin && git -C <main worktree> worktree add -b <branch> <new worktree path> origin/main`
2. Edit and test in the new worktree only (see hooks-testing.md). All suites must report 0 failed.
3. Open a pull request. Describe behavior, testing, known limits and how to switch it on. Text on this public repo must contain no hostnames, addresses, emails or machine names.
4. Merge. Do not stack a pull request on an unmerged branch (see errors.md).
5. Fast-forward the main worktree (`git -C <main worktree> pull --ff-only`) so what it serves picks up the merge.
6. NEW hook only: register it in both Claude settings files with the event and matcher from its header comment (see hooks-overview.md). A changed existing hook needs no registration.
7. If it needs a local config file, create one from the `*.conf.example`, outside the repo.
8. Remove the worktree with `git worktree remove` after the merge.

## Adding a new hook: checklist
- Header comment stating the event, matcher, what it enforces and its off switch.
- Fails open on malformed input and missing tools; deny output built with jq or Python.
- An off switch (environment variable, and for gates the 12h off-file via `_gate-common.sh`).
- A `tests/run-<name>-tests.sh` suite beside the others, with allow and deny payloads, using a throwaway HOME and no network.
- Environment-specific values in a local config file read as data, with a fake-valued `*.conf.example` committed.
- Add it to hooks-overview.md and hooks-testing.md.
