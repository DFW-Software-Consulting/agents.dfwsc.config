# Shipping a hook change

Hook files in this repository reach a live session only through a long-lived main worktree that serves the live scripts. Settings files and local config files are not in this repository.

## Steps
1. Create a branch in a new worktree off the default branch. Run git through the long-lived main worktree, not the primary checkout:
   `git -C <long-lived main worktree> fetch origin && git -C <long-lived main worktree> worktree add -b <branch> <new worktree path> origin/main`
2. Edit and test in the new worktree only (see hooks-testing.md). All suites must print `failed: 0`.
3. Open a pull request from the branch. Describe behavior, how it was tested, known limits and how to switch it on. Commit and PR text on this public repository must contain no hostnames, addresses, emails or machine names.
4. Merge. Do not stack a pull request on another unmerged branch: merge the stacked one into its base first (see errors.md).
5. Fast-forward the long-lived main worktree so the live scripts pick up the merge (`git -C <long-lived main worktree> pull --ff-only`).
6. Only for a NEW hook: register it in both Claude settings files, with the event and matcher given in the script header (see hooks-overview.md). A changed existing hook needs no registration.
7. If the hook needs a local config file, create it from the `*.conf.example` outside the repository.

## Where things live
- Scripts: tracked here under `ai-code-agents/claude/local-hooks/` and `hooks/`; the live location is `~/.claude/local-hooks` and `~/.claude/hooks`, served from the long-lived main worktree.
- Settings files (user-level and the personal config's equivalent) and local config files such as the gate configs and clock reminders: outside this repository.
- `setup-agent-configs.sh` does not link the hook directories.
- Remove a worktree with `git worktree remove` after its pull request merges.
