#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [claude|claude-personal|opencode|codex|plannotator|all]\n' "${0##*/}"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-all}"

link_path() {
  local source="$1"
  local target_path="$2"

  if [ -e "$target_path" ] && [ "$source" -ef "$target_path" ]; then
    return
  fi

  ln -sfn "$source" "$target_path"
}

install_codex_only_toggle() {
  local script="$repo_root/ai-code-agents/opencode/tools/codex-only.sh"
  local state_file="$HOME/.config/opencode/codex-only.env"
  local bin_dir="$HOME/.local/bin"
  local zshrc="$HOME/.zshrc"
  local begin_marker="# >>> agents.dfwsc.config codex-only >>>"
  local end_marker="# <<< agents.dfwsc.config codex-only <<<"
  local block

  chmod +x "$script"
  mkdir -p "$HOME/.config/opencode" "$bin_dir"
  link_path "$script" "$bin_dir/codex-only"

  if [ ! -f "$state_file" ]; then
    printf 'export OPENCODE_CODEX_ONLY=0\n' > "$state_file"
  fi

  block=$(cat <<EOF
$begin_marker
_OC_CODEX_ONLY="$script"
if [ -x "\$_OC_CODEX_ONLY" ]; then
  eval "\$("\$_OC_CODEX_ONLY" exports)"
fi
codex-only() {
  if [ -x "\$_OC_CODEX_ONLY" ]; then
    "\$_OC_CODEX_ONLY" "\$@"
    eval "\$("\$_OC_CODEX_ONLY" exports)"
  else
    echo "codex-only script not found: \$_OC_CODEX_ONLY" >&2
    return 1
  fi
}
$end_marker
EOF
)

  touch "$zshrc"
  if grep -Fq "$begin_marker" "$zshrc"; then
    python3 - "$zshrc" "$begin_marker" "$end_marker" "$block" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]
block = sys.argv[4]
text = path.read_text()
start = text.index(begin)
finish = text.index(end, start) + len(end)
path.write_text(text[:start] + block + text[finish:])
PY
  else
    printf '\n%s\n' "$block" >> "$zshrc"
  fi
}

link_claude() {
  mkdir -p "$HOME/.claude/agents"

  link_path "$repo_root/ai-code-agents/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  link_path "$repo_root/ai-code-agents/claude/settings.json" "$HOME/.claude/settings.json"
  link_path "$repo_root/ai-code-agents/claude/commands" "$HOME/.claude/commands"
  link_path "$repo_root/ai-code-agents/claude/skills" "$HOME/.claude/skills"

  for agent in \
    orchestrator \
    codebase-locator \
    codebase-analyzer \
    context-synthesis \
    antipattern-sniffer \
    typecheck \
    test-runner \
    lint \
    prettier \
    git-workflow \
    database-optimizer \
    devops-troubleshooter \
    performance-engineer; do
    link_path "$repo_root/ai-code-agents/claude/agents/$agent.md" "$HOME/.claude/agents/$agent.md"
  done
}

link_claude_personal() {
  mkdir -p "$HOME/.claude-personal/agents"

  link_path "$repo_root/ai-code-agents/claude/commands" "$HOME/.claude-personal/commands"
  link_path "$repo_root/ai-code-agents/claude/skills" "$HOME/.claude-personal/skills"

  for agent in \
    orchestrator \
    codebase-locator \
    codebase-analyzer \
    context-synthesis \
    antipattern-sniffer \
    typecheck \
    test-runner \
    lint \
    prettier \
    git-workflow \
    database-optimizer \
    devops-troubleshooter \
    performance-engineer; do
    link_path "$repo_root/ai-code-agents/claude/agents/$agent.md" "$HOME/.claude-personal/agents/$agent.md"
  done
}

link_opencode() {
  mkdir -p "$HOME/.config/opencode/tools"

  link_path "$repo_root/ai-code-agents/opencode/global.opencode.json" "$HOME/.config/opencode/opencode.json"
  link_path "$repo_root/ai-code-agents/opencode/agents" "$HOME/.config/opencode/agents"
  link_path "$repo_root/ai-code-agents/opencode/commands" "$HOME/.config/opencode/commands"
  link_path "$repo_root/ai-code-agents/opencode/skills" "$HOME/.config/opencode/skills"
  link_path "$repo_root/ai-code-agents/opencode/tools/db-readonly.mjs" "$HOME/.config/opencode/tools/db-readonly.mjs"
  install_codex_only_toggle

  if command -v npm >/dev/null 2>&1; then
    npm install --prefix "$HOME/.config/opencode" better-sqlite3 pg mysql2 mssql
  else
    printf 'npm not found; skipping OpenCode DB wrapper dependencies.\n' >&2
  fi
}

link_codex() {
  mkdir -p "$HOME/.codex/agents" "$HOME/.codex/prompts" "$HOME/.agents"

  link_path "$repo_root/ai-code-agents/codex/AGENTS.md" "$HOME/.codex/AGENTS.md"
  link_path "$repo_root/ai-code-agents/codex/config.toml" "$HOME/.codex/config.toml"
  link_path "$repo_root/ai-code-agents/codex/agents" "$HOME/.codex/agents"
  link_path "$repo_root/ai-code-agents/codex/prompts" "$HOME/.codex/prompts"
  link_path "$repo_root/ai-code-agents/codex/skills" "$HOME/.agents/skills"
}

install_plannotator() {
  if command -v plannotator >/dev/null 2>&1; then
    printf 'Plannotator already installed: %s\n' "$(command -v plannotator)"
    return
  fi

  curl -fsSL https://plannotator.ai/install.sh | bash
}

case "$target" in
  claude)
    link_claude
    ;;
  claude-personal)
    link_claude_personal
    ;;
  opencode)
    link_opencode
    ;;
  codex)
    link_codex
    ;;
  plannotator)
    install_plannotator
    ;;
  all)
    link_claude
    link_claude_personal
    link_opencode
    link_codex
    install_plannotator
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

printf 'Set up %s from %s\n' "$target" "$repo_root"
printf 'Restart Claude Code/OpenCode/Codex after changing linked config files.\n'
