#!/usr/bin/env bash
# wt-status.sh - Show status of ALL worktrees at once
# Gives you a bird's eye view of all your worktrees
#
# Usage: wt-status.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Parse arguments
OFFLINE=false
for arg in "$@"; do
    case $arg in
        --offline|-o)
            OFFLINE=true
            ;;
        --help|-h)
            echo "Usage: wt-status.sh [--offline]"
            echo ""
            echo "Show status of all worktrees at once."
            echo ""
            echo "Options:"
            echo "  --offline, -o    Skip git fetch (use cached data)"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

echo -e "${BLUE}=== All Worktrees Status ===${NC}"
echo ""

# Check we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Not in a git repository${NC}"
    exit 1
fi

# Detect remote (prefer 'origin', but auto-detect if missing)
REMOTE=$(git config --get clone.defaultRemoteName 2>/dev/null || echo "origin")
if ! git remote | grep -q "^${REMOTE}$"; then
    # Find first available remote
    REMOTE=$(git remote | head -1 || echo "")
fi

# Detect main branch (try multiple conventions)
MAIN_BRANCH=""
for branch in main master trunk default; do
    if [[ -n "$REMOTE" ]] && git rev-parse "${REMOTE}/${branch}" >/dev/null 2>&1; then
        MAIN_BRANCH="$branch"
        break
    fi
done

if [[ -z "$MAIN_BRANCH" ]]; then
    echo -e "${YELLOW}WARNING: Could not detect main branch, using 'master' as default${NC}"
    MAIN_BRANCH="master"
fi

# Fetch latest (quietly) - skip if offline
if [[ "$OFFLINE" == false ]]; then
    if [[ -n "$REMOTE" ]]; then
        git fetch "${REMOTE}" --quiet 2>/dev/null || true
    fi
else
    echo -e "${DIM}Offline mode: skipping fetch${NC}"
    echo ""
fi

# Portable timestamp to age calculation (GNU/BSD date compatible)
age_from_timestamp() {
    local timestamp="$1"
    local created_ts=""
    local now_ts=""

    # Try GNU date first
    if created_ts=$(date -d "$timestamp" +%s 2>/dev/null); then
        now_ts=$(date +%s)
    # Try BSD date (macOS)
    elif created_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$timestamp" +%s 2>/dev/null); then
        now_ts=$(date +%s)
    # Try parsing ISO-8601 without timezone
    elif created_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${timestamp%?}" +%s 2>/dev/null); then
        now_ts=$(date +%s)
    else
        echo "unknown"
        return 1
    fi

    local age_secs=$((now_ts - created_ts))

    if [[ $age_secs -lt 3600 ]]; then
        echo "$((age_secs / 60))m ago"
    elif [[ $age_secs -lt 86400 ]]; then
        echo "$((age_secs / 3600))h ago"
    else
        echo "$((age_secs / 86400))d ago"
    fi

    # Return age in seconds for stale detection
    echo "$age_secs"
}

# Get all worktrees
WORKTREES=$(git worktree list --porcelain)

CURRENT_PATH=""
CURRENT_BRANCH=""
WORKTREE_COUNT=0

while IFS= read -r line; do
    if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
        CURRENT_PATH="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
        CURRENT_BRANCH="${BASH_REMATCH[1]}"
    elif [[ "$line" == "" && -n "$CURRENT_PATH" ]]; then
        # End of worktree entry, print info
        WORKTREE_COUNT=$((WORKTREE_COUNT + 1))

        echo -e "${BOLD}[$WORKTREE_COUNT] ${BLUE}${CURRENT_PATH}${NC}"
        echo -e "    Branch: ${CURRENT_BRANCH:-detached HEAD}"

        if [[ -n "$CURRENT_BRANCH" && -d "$CURRENT_PATH" ]]; then
            # Check for metadata file and show age
            META_FILE="${CURRENT_PATH}/.worktree-meta"
            if [[ -f "$META_FILE" ]]; then
                CREATED=$(grep "^created:" "$META_FILE" | cut -d' ' -f2-)
                if [[ -n "$CREATED" ]]; then
                    AGE_INFO=$(age_from_timestamp "$CREATED")
                    AGE=$(echo "$AGE_INFO" | head -1)
                    AGE_SECS=$(echo "$AGE_INFO" | tail -1)

                    # Warn if older than 3 days
                    if [[ "$AGE_SECS" -gt 259200 ]]; then
                        echo -e "    Created: ${RED}${AGE} (STALE?)${NC}"
                    else
                        echo -e "    Created: ${DIM}${AGE}${NC}"
                    fi
                fi
                ISSUE=$(grep "^issue:" "$META_FILE" | cut -d' ' -f2-)
                if [[ -n "$ISSUE" ]]; then
                    echo -e "    Issue: ${DIM}#${ISSUE}${NC}"
                fi
            fi

            # Get commits ahead
            COMMITS_AHEAD="?"
            if [[ -n "$REMOTE" ]]; then
                COMMITS_AHEAD=$(git -C "$CURRENT_PATH" rev-list --count "${REMOTE}/${MAIN_BRANCH}..HEAD" 2>/dev/null || echo "?")
            fi

            # Check for uncommitted changes
            DIRTY=""
            if [[ -n $(git -C "$CURRENT_PATH" status --porcelain 2>/dev/null) ]]; then
                DIRTY=" ${YELLOW}(uncommitted changes)${NC}"
            fi

            # Check if pushed to remote
            PUSHED=""
            if [[ -n "$REMOTE" ]] && git rev-parse "${REMOTE}/${CURRENT_BRANCH}" >/dev/null 2>&1; then
                LOCAL_HEAD=$(git -C "$CURRENT_PATH" rev-parse HEAD 2>/dev/null)
                REMOTE_HEAD=$(git rev-parse "${REMOTE}/${CURRENT_BRANCH}" 2>/dev/null)
                if [[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]]; then
                    PUSHED=" ${GREEN}(pushed)${NC}"
                else
                    PUSHED=" ${YELLOW}(unpushed commits)${NC}"
                fi
            fi

            if [[ "$COMMITS_AHEAD" == "0" ]]; then
                echo -e "    Status: ${GREEN}Clean (at ${REMOTE:-remote}/${MAIN_BRANCH})${NC}${DIRTY}"
            else
                echo -e "    Status: ${YELLOW}${COMMITS_AHEAD} commits ahead${NC}${DIRTY}${PUSHED}"
            fi
        fi

        echo ""
        CURRENT_PATH=""
        CURRENT_BRANCH=""
    fi
done <<< "$WORKTREES"

# Handle last entry if no trailing newline
if [[ -n "$CURRENT_PATH" ]]; then
    WORKTREE_COUNT=$((WORKTREE_COUNT + 1))
    echo -e "${BOLD}[$WORKTREE_COUNT] ${BLUE}${CURRENT_PATH}${NC}"
    echo -e "    Branch: ${CURRENT_BRANCH:-detached HEAD}"
    echo ""
fi

echo -e "${DIM}Total: ${WORKTREE_COUNT} worktree(s)${NC}"
echo ""
echo -e "${BOLD}Legend:${NC}"
echo -e "  ${GREEN}Clean${NC} = Fresh from ${MAIN_BRANCH}, no commits"
echo -e "  ${YELLOW}X commits ahead${NC} = Has work on it"
echo -e "  ${YELLOW}(uncommitted changes)${NC} = Dirty working directory"
echo -e "  ${GREEN}(pushed)${NC} = Remote branch is up to date"
