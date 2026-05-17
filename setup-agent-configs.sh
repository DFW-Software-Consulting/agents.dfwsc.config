#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [claude|opencode|plannotator|all]\n' "${0##*/}"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-all}"

link_claude() {
  mkdir -p "$HOME/.claude/agents"

  ln -sf "$repo_root/ai-code-agents/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  ln -sf "$repo_root/ai-code-agents/claude/settings.json" "$HOME/.claude/settings.json"
  ln -sfn "$repo_root/ai-code-agents/claude/commands" "$HOME/.claude/commands"
  ln -sfn "$repo_root/ai-code-agents/claude/skills" "$HOME/.claude/skills"

  for agent in \
    codebase-locator \
    codebase-analyzer \
    context-synthesis \
    antipattern-sniffer \
    typecheck \
    test-runner \
    database-optimizer \
    devops-troubleshooter \
    performance-engineer; do
    ln -sf "$repo_root/ai-code-agents/claude/agents/$agent.md" "$HOME/.claude/agents/$agent.md"
  done
}

link_opencode() {
  mkdir -p "$HOME/.config/opencode/tools"

  ln -sf "$repo_root/ai-code-agents/opencode/global.opencode.json" "$HOME/.config/opencode/opencode.json"
  ln -sfn "$repo_root/ai-code-agents/opencode/agents" "$HOME/.config/opencode/agents"
  ln -sfn "$repo_root/ai-code-agents/opencode/commands" "$HOME/.config/opencode/commands"
  ln -sfn "$repo_root/ai-code-agents/opencode/skills" "$HOME/.config/opencode/skills"
  ln -sf "$repo_root/ai-code-agents/opencode/tools/db-readonly.mjs" "$HOME/.config/opencode/tools/db-readonly.mjs"

  if command -v npm >/dev/null 2>&1; then
    npm install --prefix "$HOME/.config/opencode" better-sqlite3 pg mysql2 mssql
  else
    printf 'npm not found; skipping OpenCode DB wrapper dependencies.\n' >&2
  fi
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
  opencode)
    link_opencode
    ;;
  plannotator)
    install_plannotator
    ;;
  all)
    link_claude
    link_opencode
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
printf 'Restart Claude Code/OpenCode after changing linked config files.\n'
