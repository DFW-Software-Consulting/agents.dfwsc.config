#!/usr/bin/env bash
# wt-install.sh - Install worktree-hygiene scripts to your system
# Usage: wt-install.sh [--install-dir DIR] [--symlink]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Default installation directory
INSTALL_DIR="${HOME}/.local/bin"
USE_SYMLINK=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir|-d)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --symlink|-s)
            USE_SYMLINK=true
            shift
            ;;
        --help|-h)
            echo "Usage: wt-install.sh [options]"
            echo ""
            echo "Install worktree-hygiene scripts to your system."
            echo ""
            echo "Options:"
            echo "  --install-dir, -d DIR    Installation directory (default: ~/.local/bin)"
            echo "  --symlink, -s            Create symlinks instead of copying"
            echo "  --help, -h               Show this help"
            echo ""
            echo "This will install the following scripts:"
            echo "  wt-new.sh      - Create a fresh worktree"
            echo "  wt-check.sh    - Check branch state before work"
            echo "  wt-precommit.sh - Verify before committing"
            echo "  wt-status.sh   - Show all worktrees status"
            echo "  wt-cleanup.sh  - Remove finished worktrees"
            echo ""
            echo "After installation, you may need to add ${INSTALL_DIR} to your PATH:"
            echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Run 'wt-install.sh --help' for usage"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}=== Worktree Hygiene Installation ===${NC}"
echo ""

# Check if script directory exists
if [[ ! -d "$SCRIPT_DIR" ]]; then
    echo -e "${RED}ERROR: Script directory not found: ${SCRIPT_DIR}${NC}"
    exit 1
fi

# Scripts to install (without .sh extension for final links)
SCRIPTS=("wt-new" "wt-check" "wt-precommit" "wt-status" "wt-cleanup")

# Create installation directory if it doesn't exist
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo -e "${YELLOW}Creating installation directory: ${INSTALL_DIR}${NC}"
    mkdir -p "$INSTALL_DIR"
fi

echo -e "${YELLOW}Installing scripts to: ${INSTALL_DIR}${NC}"
echo ""

# Install each script
for script in "${SCRIPTS[@]}"; do
    script_file="${SCRIPT_DIR}/${script}.sh"

    if [[ ! -f "$script_file" ]]; then
        echo -e "${RED}WARNING: ${script_file} not found, skipping${NC}"
        continue
    fi

    target="${INSTALL_DIR}/${script}"

    # Remove existing file/symlink
    if [[ -e "$target" || -L "$target" ]]; then
        echo -e "${DIM}Removing existing ${target}${NC}"
        rm -rf "$target"
    fi

    # Install
    if [[ "$USE_SYMLINK" == true ]]; then
        echo -e "${GREEN}Symlinking:${NC} ${script} -> ${target}"
        ln -s "$script_file" "$target"
    else
        echo -e "${GREEN}Copying:${NC} ${script} -> ${target}"
        cp "$script_file" "$target"
        chmod +x "$target"
    fi
done

echo ""
echo -e "${GREEN}=== Installation Complete ===${NC}"
echo ""

# Check if INSTALL_DIR is in PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo -e "${YELLOW}WARNING: ${INSTALL_DIR} is not in your PATH${NC}"
    echo ""
    echo "Add one of the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
    echo ""
    echo -e "  ${BOLD}export PATH=\"${INSTALL_DIR}:\$PATH\"${NC}"
    echo ""
    echo "Then restart your shell or run:"
    echo "  source ~/.bashrc  # or ~/.zshrc"
else
    echo -e "${GREEN}${INSTALL_DIR} is already in your PATH${NC}"
    echo ""
    echo "You can now use the scripts from anywhere:"
    echo "  wt-new.sh 123"
    echo "  wt-status.sh"
    echo "  wt-precommit.sh"
fi

# Run a quick dependency check
echo ""
echo -e "${BOLD}=== Dependency Check ===${NC}"

if command -v git >/dev/null 2>&1; then
    git_version=$(git --version)
    echo -e "${GREEN}git:${NC} ${git_version}"
else
    echo -e "${RED}git:${NC} NOT FOUND - Required for worktree operations"
fi

# Check git worktree support
if command -v git >/dev/null 2>&1; then
    if git worktree --help >/dev/null 2>&1; then
        echo -e "${GREEN}git worktree:${NC} Supported"
    else
        echo -e "${RED}git worktree:${NC} NOT SUPPORTED - Upgrade git to 2.5+"
    fi
fi

echo ""
echo -e "${GREEN}Installation successful!${NC}"
