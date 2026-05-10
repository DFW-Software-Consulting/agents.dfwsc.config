# DFWSC Agents Config

This repository is the central home for DFWSC AI coding agent configuration, engineering standards, and day-to-day development workflow templates.

## What This Project Is For

Use this project to keep AI agent setup and engineering process docs in one place so teams can work consistently across tools.

## What's Included

| Directory | Purpose |
|-----------|---------|
| **[ai-code-agents/](ai-code-agents/)** | Agent setup, custom commands, and reusable skills |
| **[engineering-principles/](engineering-principles/)** | SOP, templates, and shared engineering standards |

## Quick Links

- **[SOP](engineering-principles/SOP.md)** — AI-assisted development workflow (4-gate process)
- **[Work Issue Template](engineering-principles/git/work-issue.md)** — Gate 1 and 2 templates
- **[Work PR Template](engineering-principles/git/work-pr.md)** — Gate 4 verification template
- **[AI Agent Configs](ai-code-agents/)** — Cline, OpenCode, and Claude Code setup guides

## Getting Started

1. Read the **[SOP](engineering-principles/SOP.md)** to understand the workflow.
2. Use the **[work issue template](engineering-principles/git/work-issue.md)** when starting new work.
3. Configure your AI agents using the guides in **[ai-code-agents/](ai-code-agents/)**.

## New Machine Setup

Clone the repo first:
```bash
git clone git@github.com:DFW-Software-Consulting/agents.dfwsc.config.git ~/dfwsc/agents.dfwsc.config
```

Then symlink the configs for whichever tools you use. The symlinks point your local tool config at the repo so changes stay in sync automatically.

### OpenCode

```bash
# Global config (model, providers, agent model assignments)
mkdir -p ~/.config/opencode
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/opencode/global.opencode.json ~/.config/opencode/opencode.json
```

Add your API keys to your shell profile (`~/.bashrc` or `~/.zshrc`):
```bash
export OPENROUTER_API_KEY=your-key-here
# If using OpenCode Zen, connect via /connect inside OpenCode
```

Install the plannotator binary (for plan review UI):
```bash
curl -fsSL https://plannotator.ai/install.sh | bash
```

### Claude Code

```bash
# Global instructions and settings
mkdir -p ~/.claude/agents
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/CLAUDE.md ~/.claude/CLAUDE.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/settings.json ~/.claude/settings.json

# Global subagents (available in all projects)
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/codebase-locator.md ~/.claude/agents/codebase-locator.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/codebase-analyzer.md ~/.claude/agents/codebase-analyzer.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/context-synthesis.md ~/.claude/agents/context-synthesis.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/antipattern-sniffer.md ~/.claude/agents/antipattern-sniffer.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/typecheck.md ~/.claude/agents/typecheck.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/test-runner.md ~/.claude/agents/test-runner.md
```

Specialist agents (backend-architect, cloud-architect, etc.) are best copied per-project into `.claude/agents/` as needed rather than linked globally.

### Gemini CLI

```bash
mkdir -p ~/.gemini/agents
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/gemini/GEMINI.md ~/.gemini/GEMINI.md
```

### Reload shell

```bash
source ~/.bashrc  # or ~/.zshrc
```

## Contributing

- Place AI agent configurations in `ai-code-agents/`.
- Place engineering standards in `engineering-principles/`.
- Follow the 4-gate workflow defined in the SOP.
