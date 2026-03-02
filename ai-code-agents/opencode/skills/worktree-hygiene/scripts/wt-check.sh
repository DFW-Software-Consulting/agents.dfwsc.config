#!/usr/bin/env bash
# wt-check.sh - Check branch state BEFORE starting work
# Run this when entering a worktree to verify it's clean
#
# Usage: wt-check.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Parse arguments
OFFLINE=false
for arg in "$@"; do
    case $arg in
        --offline|-o)
            OFFLINE=true
            ;;
        --help|-h)
            echo "Usage: wt-check.sh [--offline]"
            echo ""
            echo "Check branch state BEFORE starting work."
            echo ""
            echo "Options:"
            echo "  --offline, -o    Skip git fetch (use cached data)"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

echo -e "${BLUE}=== Worktree Pre-Work Check ===${NC}"
echo ""

# Check we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Not in a git repository${NC}"
    exit 1
fi

BRANCH=$(git branch --show-current)
echo -e "${BOLD}Current branch:${NC} ${BLUE}${BRANCH}${NC}"
echo ""

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

# Check for uncommitted changes
echo -e "${BOLD}1. Uncommitted changes:${NC}"
if [[ -n $(git status --porcelain) ]]; then
    echo -e "${YELLOW}   WARNING: You have uncommitted changes${NC}"
    git status --short | head -10
    UNCOMMITTED_COUNT=$(git status --porcelain | wc -l)
    if [[ $UNCOMMITTED_COUNT -gt 10 ]]; then
        echo "   ... and $((UNCOMMITTED_COUNT - 10)) more"
    fi
else
    echo -e "${GREEN}   Clean - no uncommitted changes${NC}"
fi
echo ""

# Check commits ahead of main
echo -e "${BOLD}2. Commits ahead of ${REMOTE}/${MAIN_BRANCH}:${NC}"
if [[ "$OFFLINE" == false && -n "$REMOTE" ]]; then
    git fetch "${REMOTE}" "${MAIN_BRANCH}" --quiet 2>/dev/null || true
fi

COMMITS_AHEAD="0"
if [[ -n "$REMOTE" ]]; then
    COMMITS_AHEAD=$(git rev-list --count "${REMOTE}/${MAIN_BRANCH}..HEAD" 2>/dev/null || echo "0")
fi

if [[ "$COMMITS_AHEAD" -eq 0 ]]; then
    echo -e "${GREEN}   Clean - branch is at ${REMOTE}/${MAIN_BRANCH}${NC}"
elif [[ "$COMMITS_AHEAD" -le 3 ]]; then
    echo -e "${YELLOW}   ${COMMITS_AHEAD} commit(s) ahead of ${REMOTE}/${MAIN_BRANCH}:${NC}"
    if [[ -n "$REMOTE" ]]; then
        git log --oneline "${REMOTE}/${MAIN_BRANCH}..HEAD"
    fi
else
    echo -e "${RED}   WARNING: ${COMMITS_AHEAD} commits ahead of ${REMOTE}/${MAIN_BRANCH}${NC}"
    echo -e "${RED}   This branch may have OTHER work on it!${NC}"
    echo ""
    echo "   Recent commits:"
    if [[ -n "$REMOTE" ]]; then
        git log --oneline "${REMOTE}/${MAIN_BRANCH}..HEAD" | head -5
    fi
    echo "   ..."
fi
echo ""

# Check files changed vs main
echo -e "${BOLD}3. Files different from ${REMOTE}/${MAIN_BRANCH}:${NC}"
FILES_CHANGED="0"
if [[ -n "$REMOTE" ]]; then
    FILES_CHANGED=$(git diff --name-only "${REMOTE}/${MAIN_BRANCH}...HEAD" 2>/dev/null | wc -l || echo "0")
fi

if [[ "$FILES_CHANGED" -eq 0 ]]; then
    echo -e "${GREEN}   Clean - no file changes${NC}"
elif [[ "$FILES_CHANGED" -le 10 ]]; then
    echo -e "${YELLOW}   ${FILES_CHANGED} file(s) changed:${NC}"
    if [[ -n "$REMOTE" ]]; then
        git diff --stat "${REMOTE}/${MAIN_BRANCH}...HEAD" 2>/dev/null | tail -$((FILES_CHANGED + 1))
    fi
else
    echo -e "${RED}   WARNING: ${FILES_CHANGED} files changed from ${REMOTE}/${MAIN_BRANCH}${NC}"
    echo ""
    if [[ -n "$REMOTE" ]]; then
        git diff --stat "${REMOTE}/${MAIN_BRANCH}...HEAD" 2>/dev/null | tail -15
    fi
fi
echo ""

# Final verdict
echo -e "${BOLD}=== VERDICT ===${NC}"
if [[ "$COMMITS_AHEAD" -eq 0 && "$FILES_CHANGED" -eq 0 ]]; then
    echo -e "${GREEN}CLEAN: This branch is fresh from ${MAIN_BRANCH}. Safe to work.${NC}"
    exit 0
elif [[ "$COMMITS_AHEAD" -gt 0 ]]; then
    echo -e "${RED}CONTAMINATED: This branch has ${COMMITS_AHEAD} existing commit(s).${NC}"
    echo ""
    echo "If these commits are NOT your current work:"
    echo -e "  ${YELLOW}1. Do NOT commit here${NC}"
    echo -e "  ${YELLOW}2. Create a fresh worktree: wt-new.sh <issue-name>${NC}"
    echo ""
    echo "If these commits ARE your current work:"
    echo "  Continue working (this is expected)"
    exit 1
else
    echo -e "${YELLOW}UNCERTAIN: No commits but uncommitted changes present.${NC}"
    exit 0
fi
