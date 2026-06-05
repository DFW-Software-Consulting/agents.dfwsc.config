#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [claude|opencode|codex|plannotator|all]\n' "${0##*/}"
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

link_claude() {
  mkdir -p "$HOME/.claude/agents"

  link_path "$repo_root/ai-code-agents/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  link_path "$repo_root/ai-code-agents/claude/settings.json" "$HOME/.claude/settings.json"
  link_path "$repo_root/ai-code-agents/claude/commands" "$HOME/.claude/commands"
  link_path "$repo_root/ai-code-agents/claude/skills" "$HOME/.claude/skills"

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
    link_path "$repo_root/ai-code-agents/claude/agents/$agent.md" "$HOME/.claude/agents/$agent.md"
  done
}

link_opencode() {
  mkdir -p "$HOME/.opencode/tools"

  link_path "$repo_root/ai-code-agents/opencode/global.opencode.json" "$HOME/.opencode/opencode.json"
  link_path "$repo_root/ai-code-agents/opencode/agents" "$HOME/.opencode/agents"
  link_path "$repo_root/ai-code-agents/opencode/commands" "$HOME/.opencode/commands"
  link_path "$repo_root/ai-code-agents/opencode/skills" "$HOME/.opencode/skills"
  link_path "$repo_root/ai-code-agents/opencode/tools/db-readonly.mjs" "$HOME/.opencode/tools/db-readonly.mjs"

  if command -v npm >/dev/null 2>&1; then
    npm install --prefix "$HOME/.opencode" better-sqlite3 pg mysql2 mssql
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
