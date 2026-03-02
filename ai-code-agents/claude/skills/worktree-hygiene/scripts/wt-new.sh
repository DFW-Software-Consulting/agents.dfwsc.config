#!/usr/bin/env bash
# wt-new.sh - Create a fresh worktree with proper hygiene
# Usage: wt-new.sh <issue-number-or-name> [base-branch]
#
# Examples:
#   wt-new.sh 123              # Creates worktree for issue #123
#   wt-new.sh add-auth         # Creates worktree for feature
#   wt-new.sh 123 develop      # Creates from develop instead of master

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
OFFLINE=false
WORKTREE_BASE=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --offline|-o)
            OFFLINE=true
            shift
            ;;
        --worktree-dir|-w)
            WORKTREE_BASE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: wt-new.sh <issue-number-or-name> [base-branch] [options]"
            echo ""
            echo "Create a fresh worktree with proper hygiene."
            echo ""
            echo "Arguments:"
            echo "  issue-number-or-name    Issue number or feature name"
            echo "  base-branch             Base branch (default: auto-detected main)"
            echo ""
            echo "Options:"
            echo "  --offline, -o           Skip git fetch"
            echo "  --worktree-dir, -w DIR  Base directory for worktrees"
            echo "  --help, -h              Show this help"
            echo ""
            echo "Examples:"
            echo "  wt-new.sh 123               # Creates fix/issue-123 from detected main"
            echo "  wt-new.sh add-auth          # Creates fix/add-auth from detected main"
            echo "  wt-new.sh 123 develop       # Creates from origin/develop"
            echo "  wt-new.sh 123 -w ~/wt       # Custom worktree location"
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional arguments
set -- "${POSITIONAL_ARGS[@]}"

if [[ $# -lt 1 ]]; then
    echo -e "${RED}Usage: wt-new.sh <issue-number-or-name> [base-branch] [options]${NC}"
    echo "Run 'wt-new.sh --help' for more information"
    exit 1
fi

ISSUE_OR_NAME="$1"
BASE_BRANCH="${2:-}"

# Detect remote (prefer 'origin', but auto-detect if missing)
REMOTE=$(git config --get clone.defaultRemoteName 2>/dev/null || echo "origin")
if ! git remote | grep -q "^${REMOTE}$"; then
    REMOTE=$(git remote | head -1 || echo "")
fi

if [[ -z "$REMOTE" ]]; then
    echo -e "${RED}ERROR: No git remote found${NC}"
    exit 1
fi

# Auto-detect base branch if not specified
if [[ -z "$BASE_BRANCH" ]]; then
    for branch in main master trunk default; do
        if git rev-parse "${REMOTE}/${branch}" >/dev/null 2>&1; then
            BASE_BRANCH="$branch"
            break
        fi
    done
    if [[ -z "$BASE_BRANCH" ]]; then
        echo -e "${YELLOW}WARNING: Could not detect main branch, using 'master' as default${NC}"
        BASE_BRANCH="master"
    fi
    echo -e "${DIM}Auto-detected base branch: ${BASE_BRANCH}${NC}"
fi

# Determine branch name
if [[ "$ISSUE_OR_NAME" =~ ^[0-9]+$ ]]; then
    BRANCH_NAME="fix/issue-${ISSUE_OR_NAME}"
else
    BRANCH_NAME="fix/${ISSUE_OR_NAME}"
fi

# Get repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$REPO_ROOT" ]]; then
    echo -e "${RED}ERROR: Not in a git repository${NC}"
    exit 1
fi

# Determine worktree directory
if [[ -z "$WORKTREE_BASE" ]]; then
    # Check for configured location
    WORKTREE_BASE=$(git config --get worktree.baseDir 2>/dev/null || echo "")
    if [[ -z "$WORKTREE_BASE" ]]; then
        WORKTREE_BASE="${REPO_ROOT}/../worktrees"
    fi
fi
WORKTREE_DIR="${WORKTREE_BASE}/${BRANCH_NAME##*/}"

echo -e "${BLUE}=== Creating Fresh Worktree ===${NC}"
echo ""

# Fetch latest from remote (unless offline)
if [[ "$OFFLINE" == false ]]; then
    echo -e "${YELLOW}Fetching latest from ${REMOTE}...${NC}"
    if ! git fetch "${REMOTE}"; then
        echo -e "${YELLOW}WARNING: Fetch failed, continuing with cached data${NC}"
    fi
else
    echo -e "${DIM}Offline mode: skipping fetch${NC}"
fi

# Check if base branch exists
if ! git rev-parse "${REMOTE}/${BASE_BRANCH}" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: ${REMOTE}/${BASE_BRANCH} does not exist${NC}"
    echo "Available remote branches:"
    git branch -r | grep "${REMOTE}/" | head -10
    exit 1
fi

# Check if branch already exists locally or remotely
if git rev-parse "${BRANCH_NAME}" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Branch '${BRANCH_NAME}' already exists locally${NC}"
    echo ""
    echo "Options:"
    echo "  1. Delete it first: git branch -D ${BRANCH_NAME}"
    echo "  2. Use a different name: wt-new.sh ${ISSUE_OR_NAME}-v2"
    exit 1
fi

if git rev-parse "${REMOTE}/${BRANCH_NAME}" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Branch '${BRANCH_NAME}' already exists on ${REMOTE}${NC}"
    echo ""
    echo "Options:"
    echo "  1. Use the existing branch (not recommended for fresh work)"
    echo "  2. Use a different name: wt-new.sh ${ISSUE_OR_NAME}-v2"
    exit 1
fi

# Check if worktree directory already exists
if [[ -d "$WORKTREE_DIR" ]]; then
    echo -e "${RED}ERROR: Worktree directory already exists: ${WORKTREE_DIR}${NC}"
    echo ""
    echo "Options:"
    echo "  1. Remove it: git worktree remove ${WORKTREE_DIR}"
    echo "  2. Use a different name"
    exit 1
fi

# Create the worktree
echo -e "${YELLOW}Creating worktree at: ${WORKTREE_DIR}${NC}"
echo -e "${YELLOW}Branch: ${BRANCH_NAME} (from ${REMOTE}/${BASE_BRANCH})${NC}"
echo ""

# Create worktree directory if it doesn't exist
mkdir -p "$(dirname "$WORKTREE_DIR")"

git worktree add -b "${BRANCH_NAME}" "${WORKTREE_DIR}" "${REMOTE}/${BASE_BRANCH}"

# Create metadata file with timestamp (ISO-8601 for portability)
TIMESTAMP=$(date -Iseconds 2>/dev/null || date "+%Y-%m-%dT%H:%M:%S%z")
cat > "${WORKTREE_DIR}/.worktree-meta" <<EOF
created: ${TIMESTAMP}
issue: ${ISSUE_OR_NAME}
branch: ${BRANCH_NAME}
base: ${REMOTE}/${BASE_BRANCH}
remote: ${REMOTE}
EOF

echo ""
echo -e "${GREEN}=== Worktree Created Successfully ===${NC}"
echo ""
echo -e "Location: ${BLUE}${WORKTREE_DIR}${NC}"
echo -e "Branch:   ${BLUE}${BRANCH_NAME}${NC}"
echo -e "Base:     ${BLUE}${REMOTE}/${BASE_BRANCH}${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  cd ${WORKTREE_DIR}"
echo "  # Do your work"
echo "  wt-precommit.sh  # Run before committing"
echo ""
echo -e "${GREEN}This worktree is CLEAN - no prior commits, fresh from ${BASE_BRANCH}${NC}"
