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

## New Machine Setup (OpenCode)

1. Clone the repo:
   ```bash
   git clone git@github.com:DFW-Software-Consulting/agents.dfwsc.config.git ~/dfwsc/agents.dfwsc.config
   ```

2. Add your OpenRouter API key to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):
   ```bash
   export OPENROUTER_API_KEY=your-key-here
   ```

3. Symlink the global OpenCode config:
   ```bash
   ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/opencode/global.opencode.json ~/.config/opencode/opencode.json
   ```

4. Symlink the Claude global config and settings:
   ```bash
   ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/CLAUDE.md ~/.claude/CLAUDE.md
   ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/settings.json ~/.claude/settings.json
   ```

5. Reload your shell:
   ```bash
   source ~/.bashrc  # or ~/.zshrc
   ```

## Contributing

- Place AI agent configurations in `ai-code-agents/`.
- Place engineering standards in `engineering-principles/`.
- Follow the 4-gate workflow defined in the SOP.
