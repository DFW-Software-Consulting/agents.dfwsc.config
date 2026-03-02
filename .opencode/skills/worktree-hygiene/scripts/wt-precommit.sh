#!/usr/bin/env bash
# wt-precommit.sh - Verify branch state BEFORE committing
# This is the FINAL check before you commit. Run it every time.
#
# Usage: wt-precommit.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Parse arguments
OFFLINE=false
SKIP_PROMPT=false
for arg in "$@"; do
    case $arg in
        --offline|-o)
            OFFLINE=true
            ;;
        --yes|-y)
            SKIP_PROMPT=true
            ;;
        --help|-h)
            echo "Usage: wt-precommit.sh [options]"
            echo ""
            echo "Verify branch state BEFORE committing."
            echo ""
            echo "Options:"
            echo "  --offline, -o    Skip git fetch (use cached data)"
            echo "  --yes, -y        Skip confirmation prompt"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

echo -e "${BLUE}=== Pre-Commit Verification ===${NC}"
echo ""

# Check we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Not in a git repository${NC}"
    exit 1
fi

BRANCH=$(git branch --show-current)
echo -e "${BOLD}Branch:${NC} ${BLUE}${BRANCH}${NC}"

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

# Fetch latest (unless offline)
if [[ "$OFFLINE" == false && -n "$REMOTE" ]]; then
    git fetch "${REMOTE}" "${MAIN_BRANCH}" --quiet 2>/dev/null || true
fi

echo ""
echo -e "${BOLD}=== EXISTING COMMITS ON THIS BRANCH ===${NC}"
COMMITS_AHEAD="0"
if [[ -n "$REMOTE" ]]; then
    COMMITS_AHEAD=$(git rev-list --count "${REMOTE}/${MAIN_BRANCH}..HEAD" 2>/dev/null || echo "0")
fi

if [[ "$COMMITS_AHEAD" -eq 0 ]]; then
    echo -e "${GREEN}None - this will be your first commit on this branch${NC}"
else
    echo -e "${YELLOW}Found ${COMMITS_AHEAD} existing commit(s):${NC}"
    echo ""
    if [[ -n "$REMOTE" ]]; then
        git log --oneline --format="  %h %s (%an, %ar)" "${REMOTE}/${MAIN_BRANCH}..HEAD"
    fi
    echo ""

    # Check if commits are from today/recent
    if [[ -n "$REMOTE" ]]; then
        OLDEST_COMMIT_DATE=$(git log --format="%ai" "${REMOTE}/${MAIN_BRANCH}..HEAD" | tail -1 | cut -d' ' -f1)
        TODAY=$(date +%Y-%m-%d)

        if [[ "$OLDEST_COMMIT_DATE" != "$TODAY" ]]; then
            echo -e "${RED}!!! WARNING: Oldest commit is from ${OLDEST_COMMIT_DATE} !!!${NC}"
            echo -e "${RED}!!! These may be from a DIFFERENT work session !!!${NC}"
            echo ""
        fi
    fi
fi

echo ""
echo -e "${BOLD}=== FILES ALREADY CHANGED (in existing commits) ===${NC}"
if [[ "$COMMITS_AHEAD" -gt 0 && -n "$REMOTE" ]]; then
    git diff --stat "${REMOTE}/${MAIN_BRANCH}...HEAD" 2>/dev/null
else
    echo -e "${GREEN}None${NC}"
fi

echo ""
echo -e "${BOLD}=== FILES YOU'RE ABOUT TO COMMIT (staged) ===${NC}"
STAGED=$(git diff --cached --name-only)
if [[ -z "$STAGED" ]]; then
    echo -e "${YELLOW}Nothing staged. Did you forget to 'git add'?${NC}"
else
    git diff --cached --stat
fi

echo ""
echo -e "${BOLD}=== UNSTAGED CHANGES (won't be committed) ===${NC}"
UNSTAGED=$(git diff --name-only)
if [[ -z "$UNSTAGED" ]]; then
    echo -e "${GREEN}None${NC}"
else
    git diff --stat
fi

echo ""
echo -e "${BOLD}=== VERIFICATION QUESTIONS ===${NC}"
echo ""
echo "Before you commit, verify:"
echo ""
echo -e "  ${YELLOW}1. Are the EXISTING commits (above) from YOUR current work?${NC}"
echo "     If NO: STOP. Create a fresh branch with wt-new.sh"
echo ""
echo -e "  ${YELLOW}2. Are the STAGED files (above) what you intend to commit?${NC}"
echo "     If NO: Adjust with git add/reset"
echo ""
echo -e "  ${YELLOW}3. Is this the RIGHT branch for this work?${NC}"
echo "     Branch: ${BRANCH}"
echo ""

# Interactive prompt if terminal (skip if --yes)
if [[ "$SKIP_PROMPT" == false && -t 0 ]]; then
    read -p "Proceed with commit? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Aborted.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Proceeding...${NC}"
elif [[ "$SKIP_PROMPT" == true ]]; then
    echo -e "${DIM}Skipping prompt (--yes flag)${NC}"
fi
