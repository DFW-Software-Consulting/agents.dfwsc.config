---
name: worktree-hygiene
description: Use when creating, checking, committing from, cleaning up, or managing git worktrees to prevent branch contamination.
---

# Worktree Hygiene

Strict discipline for git worktrees to prevent branch contamination - committing work to a branch that already has unrelated commits.

**Robustness Features:**
- **Auto-detection** of remote (origin, upstream, etc.) and main branch (main, master, trunk, default)
- **Offline mode** - works without network (skip git fetch)
- **Cross-platform** - works on Linux, macOS, BSD (GNU/BSD date compatible)
- **Configurable paths** - supports custom worktree locations
- **Graceful degradation** - continues even if some operations fail

## The Problem This Solves

Branch contamination happens when:
- Committing to an existing worktree branch that has other work on it
- Reusing worktrees for different tasks
- Not checking branch state before starting work

This causes merge conflicts, confused PRs, and wasted time untangling commits.

## Installation

The scripts are located in `scripts/` within this skill. To use them from anywhere:

```bash
# Run the installer
cd /path/to/worktree-hygiene/scripts
./wt-install.sh

# Or install to a custom directory
./wt-install.sh --install-dir ~/bin

# Or create symlinks instead of copying
./wt-install.sh --symlink
```

The installer will:
1. Copy/symlink scripts to `~/.local/bin` (or custom directory)
2. Make them executable
3. Check if the directory is in your PATH
4. Run a dependency check

**Manual PATH setup** (if installer warns about PATH):

Add to `~/.bashrc`, `~/.zshrc`, or equivalent:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then restart your shell or run `source ~/.bashrc`.

## Core Rules (Non-Negotiable)

### Rule 1: NEVER Reuse Worktrees

Each worktree is disposable. One issue = one worktree = one PR. After the PR merges, delete the worktree.

### Rule 2: ALWAYS Create Fresh Branches

Never commit to an existing branch. The base branch is auto-detected (main, master, trunk, or default).

```bash
wt-new.sh <issue-number-or-name>
```

### Rule 3: ALWAYS Verify Before Committing

Before every commit, run the pre-commit check:

```bash
wt-precommit.sh
```

If it shows commits you didn't make, STOP. Create a new worktree.

### Rule 4: CHECK Branch State When Entering a Worktree

When `cd`-ing into a worktree, verify its state:

```bash
wt-check.sh
```

## Scripts Reference

### `wt-new.sh` - Create Fresh Worktree

Creates a new worktree with a fresh branch. Auto-detects remote and base branch.

```bash
wt-new.sh 123                 # Creates from detected main branch
wt-new.sh add-auth            # Creates feature branch
wt-new.sh 123 develop         # Creates from develop branch
wt-new.sh 123 -w ~/wt         # Custom worktree location
wt-new.sh 123 --offline       # Skip git fetch
```

**Options:**
- `--offline, -o` - Skip git fetch (use cached data)
- `--worktree-dir, -w DIR` - Custom worktree base directory
- `--help, -h` - Show help

**Configuration:**
```bash
# Set default worktree location (per-repo)
git config worktree.baseDir ~/worktrees
```

**Guarantees:**
- Branch does not already exist locally or remotely
- Branch starts at exact commit of detected base branch
- Worktree directory is new
- Remote is auto-detected (origin, upstream, etc.)

### `wt-check.sh` - Pre-Work Verification

Run when entering a worktree to verify it's safe to work in.

```bash
wt-check.sh          # Online mode (fetches)
wt-check.sh --offline  # Offline mode
```

**Options:**
- `--offline, -o` - Skip git fetch
- `--help, -h` - Show help

**Shows:**
- Uncommitted changes
- Commits ahead of main (auto-detected branch)
- Files already changed

**Exit codes:**
- 0 = Clean, safe to work
- 1 = Contaminated, has existing commits

### `wt-precommit.sh` - Pre-Commit Verification

Run BEFORE every commit. This is the final safety check.

```bash
wt-precommit.sh        # Interactive mode
wt-precommit.sh --yes  # Skip confirmation
wt-precommit.sh -o     # Offline mode
```

**Options:**
- `--offline, -o` - Skip git fetch
- `--yes, -y` - Skip confirmation prompt
- `--help, -h` - Show help

**Shows:**
- Existing commits on the branch (are they yours?)
- Staged files (what you're about to commit)
- Unstaged files (what won't be committed)
- Age of existing commits (warning if from different day)

### `wt-status.sh` - All Worktrees Overview

Bird's eye view of all worktrees at once.

```bash
wt-status.sh           # Online mode (fetches)
wt-status.sh --offline # Offline mode (cached)
```

**Options:**
- `--offline, -o` - Skip git fetch
- `--help, -h` - Show help

**Shows for each worktree:**
- Path and branch name
- Age of worktree (with stale warning for 3+ days)
- Commits ahead of main
- Uncommitted changes
- Push status

### `wt-cleanup.sh` - Remove Finished Worktrees

Cleans up worktrees after their PRs are merged.

```bash
wt-cleanup.sh           # Actually removes
wt-cleanup.sh --dry-run # Preview only
wt-cleanup.sh -n        # Short form for --dry-run
wt-cleanup.sh -o        # Offline mode
```

**Options:**
- `--dry-run, -n` - Preview only, don't remove
- `--offline, -o` - Skip git fetch
- `--help, -h` - Show help

**Removes:**
- Worktrees whose branches were deleted from remote
- Worktrees whose branches were merged to main

### `wt-install.sh` - Installation Helper

Install scripts to your PATH.

```bash
wt-install.sh              # Install to ~/.local/bin
wt-install.sh -d ~/bin     # Custom directory
wt-install.sh --symlink    # Create symlinks
```

**Options:**
- `--install-dir, -d DIR` - Installation directory
- `--symlink, -s` - Create symlinks instead of copying
- `--help, -h` - Show help

## Workflow

### Starting New Work

```bash
# 1. Create fresh worktree (auto-detects main branch)
wt-new.sh 123

# 2. Enter the worktree
cd ../worktrees/issue-123  # or your custom location

# 3. Verify it's clean (optional but recommended)
wt-check.sh

# 4. Do your work...
```

### Before Every Commit

```bash
# ALWAYS run this before committing
wt-precommit.sh

# If it looks good, proceed
git add .
git commit -m "your message"
```

### After PR Merges

```bash
# See what can be cleaned up
wt-cleanup.sh --dry-run

# Actually clean up
wt-cleanup.sh
```

### Daily Check

```bash
# See status of all worktrees
wt-status.sh
```

### Offline Workflow

When working without network:

```bash
# All scripts support --offline flag
wt-new.sh 123 --offline
wt-check.sh --offline
wt-precommit.sh --offline
wt-status.sh --offline
wt-cleanup.sh --offline
```

## Red Flags - STOP If You See These

1. **`wt-check.sh` shows commits you didn't make** - Create a new worktree
2. **`wt-precommit.sh` shows old commits from different days** - Verify they're yours
3. **`wt-status.sh` shows a worktree with many commits** - Check if it's stale work
4. **About to commit to a branch that already has a PR** - Don't add more commits, create a new branch

## Platform Compatibility

| Feature | Linux | macOS | BSD | WSL |
|---------|-------|-------|-----|-----|
| Date parsing | GNU | BSD | BSD | GNU |
| Remote detection | | All | | |
| Main branch detection | | All | | |
| Offline mode | | All | | |
| Git version | 2.5+ | 2.5+ | 2.5+ | 2.5+ |

## Integration with CLAUDE.md

This skill enforces the Branch Hygiene Rules documented in CLAUDE.md's CRITICAL FAILURE LOG. The scripts automate the manual checks:

| Manual Check | Script |
|-------------|--------|
| `git log --oneline -5` | `wt-check.sh` |
| `git diff origin/main...HEAD --stat` | `wt-check.sh`, `wt-precommit.sh` |
| Fresh branch from main | `wt-new.sh` |

## Troubleshooting

**"scripts not found" error**
- Run `./wt-install.sh` to install to your PATH
- Or use full path: `/path/to/skill/scripts/wt-new.sh`

**"Could not detect main branch" warning**
- Scripts will fall back to `master`
- Or specify explicitly: `wt-new.sh 123 main`

**Date parsing errors on macOS**
- Scripts auto-detect GNU vs BSD date
- If issues persist, report the error with `uname -a` output

**"origin" remote doesn't exist**
- Scripts auto-detect available remotes
- Or set via git config: `git config clone.defaultRemoteName myremote`
