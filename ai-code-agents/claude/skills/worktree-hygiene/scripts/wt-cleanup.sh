#!/usr/bin/env bash
# wt-cleanup.sh - Remove finished worktrees after PR merge
# Cleans up worktrees whose branches have been merged or deleted
#
# Usage: wt-cleanup.sh [--dry-run]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

DRY_RUN=false
OFFLINE=false

for arg in "$@"; do
    case $arg in
        --dry-run|-n)
            DRY_RUN=true
            ;;
        --offline|-o)
            OFFLINE=true
            ;;
        --help|-h)
            echo "Usage: wt-cleanup.sh [options]"
            echo ""
            echo "Remove finished worktrees after PR merge."
            echo ""
            echo "Options:"
            echo "  --dry-run, -n    Preview only, don't remove anything"
            echo "  --offline, -o    Skip git fetch"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}=== DRY RUN MODE ===${NC}"
    echo ""
fi

echo -e "${BLUE}=== Worktree Cleanup ===${NC}"
echo ""

# Check we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Not in a git repository${NC}"
    exit 1
fi

# Detect remote
REMOTE=$(git config --get clone.defaultRemoteName 2>/dev/null || echo "origin")
if ! git remote | grep -q "^${REMOTE}$"; then
    REMOTE=$(git remote | head -1 || echo "")
fi

# Detect main branch
MAIN_BRANCH=""
for branch in main master trunk default; do
    if [[ -n "$REMOTE" ]] && git rev-parse "${REMOTE}/${branch}" >/dev/null 2>&1; then
        MAIN_BRANCH="$branch"
        break
    fi
done
if [[ -z "$MAIN_BRANCH" ]]; then
    MAIN_BRANCH="master"
fi

# Fetch and prune (unless offline)
if [[ "$OFFLINE" == false && -n "$REMOTE" ]]; then
    echo -e "${YELLOW}Fetching and pruning remote branches...${NC}"
    git fetch "${REMOTE}" --prune --quiet 2>/dev/null || true
else
    echo -e "${DIM}Offline mode: skipping fetch${NC}"
fi

# Get main worktree (we never remove this)
MAIN_WORKTREE=$(git worktree list --porcelain | grep "^worktree" | head -1 | cut -d' ' -f2-)

echo ""
echo -e "${BOLD}Checking worktrees for cleanup...${NC}"
echo ""

CLEANUP_COUNT=0
KEEP_COUNT=0

# Parse worktrees
git worktree list --porcelain | while IFS= read -r line; do
    if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
        WT_PATH="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
        WT_BRANCH="${BASH_REMATCH[1]}"
    elif [[ "$line" == "" && -n "${WT_PATH:-}" ]]; then
        # Skip main worktree
        if [[ "$WT_PATH" == "$MAIN_WORKTREE" ]]; then
            echo -e "${GREEN}[KEEP]${NC} ${WT_PATH}"
            echo "       Main worktree (never removed)"
            echo ""
            WT_PATH=""
            WT_BRANCH=""
            continue
        fi

        SHOULD_REMOVE=false
        REASON=""

        # Check if branch still exists on remote
        if [[ -n "${WT_BRANCH:-}" && -n "$REMOTE" ]]; then
            if ! git rev-parse "${REMOTE}/${WT_BRANCH}" >/dev/null 2>&1; then
                # Branch doesn't exist on remote - check if merged
                if git branch --merged "${REMOTE}/${MAIN_BRANCH}" 2>/dev/null | grep -q "^\s*${WT_BRANCH}$"; then
                    SHOULD_REMOVE=true
                    REASON="Branch merged and deleted from remote"
                else
                    SHOULD_REMOVE=true
                    REASON="Branch deleted from remote (may not be merged!)"
                fi
            fi
        fi

        # Check if worktree directory still exists
        if [[ ! -d "$WT_PATH" ]]; then
            SHOULD_REMOVE=true
            REASON="Worktree directory no longer exists"
        fi

        if [[ "$SHOULD_REMOVE" == true ]]; then
            CLEANUP_COUNT=$((CLEANUP_COUNT + 1))
            echo -e "${YELLOW}[REMOVE]${NC} ${WT_PATH}"
            echo "         Branch: ${WT_BRANCH:-unknown}"
            echo "         Reason: ${REASON}"

            if [[ "$DRY_RUN" == false ]]; then
                if [[ -d "$WT_PATH" ]]; then
                    git worktree remove "$WT_PATH" --force 2>/dev/null || true
                else
                    git worktree prune
                fi

                # Also delete the local branch if it exists
                if [[ -n "${WT_BRANCH:-}" ]]; then
                    git branch -D "${WT_BRANCH}" 2>/dev/null || true
                fi
                echo -e "         ${GREEN}Removed${NC}"
            fi
            echo ""
        else
            KEEP_COUNT=$((KEEP_COUNT + 1))
            echo -e "${GREEN}[KEEP]${NC} ${WT_PATH}"
            echo "       Branch: ${WT_BRANCH:-unknown}"

            # Show status
            if [[ -d "$WT_PATH" && -n "${WT_BRANCH:-}" && -n "$REMOTE" ]]; then
                COMMITS=$(git -C "$WT_PATH" rev-list --count "${REMOTE}/${MAIN_BRANCH}..HEAD" 2>/dev/null || echo "?")
                echo "       Status: ${COMMITS} commits ahead of ${MAIN_BRANCH}"
            fi
            echo ""
        fi

        WT_PATH=""
        WT_BRANCH=""
    fi
done

# Prune any orphaned worktree references
if [[ "$DRY_RUN" == false ]]; then
    git worktree prune
fi

echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}Dry run complete. Run without --dry-run to actually remove.${NC}"
else
    echo -e "${GREEN}Cleanup complete.${NC}"
fi
