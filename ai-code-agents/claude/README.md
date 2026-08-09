# Claude Code Config

Configuration for [Claude Code](https://claude.ai/code) — Anthropic's terminal AI agent.

## Setup (New Machine)

From the repo root, link Claude Code config into `~/.claude/`:

```bash
./setup-agent-configs.sh claude

# Optional: install the Plannotator CLI used by Plannotator commands/skills
./setup-agent-configs.sh plannotator
```

Manual equivalent:

```bash
mkdir -p ~/.claude

# Global instructions and settings
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/CLAUDE.md ~/.claude/CLAUDE.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/settings.json ~/.claude/settings.json
ln -sfn ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents ~/.claude/agents
ln -sfn ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/commands ~/.claude/commands
ln -sfn ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/skills ~/.claude/skills
```

The setup script refuses to replace existing real directories; move them aside manually if you want the maintained directory linked.

## GitHub MCP

GitHub MCP is configured through `~/.claude/settings.json`, which this repo's setup flow links to `ai-code-agents/claude/settings.json`.

Before launching Claude, make sure GitHub MCP can authenticate in one of these ways:

- Export `GITHUB_TOKEN` (or an equivalent token environment variable consumed by your MCP wrapper) in the shell.
- Authenticate `gh` so `github-mcp.sh` can fall back to `gh auth token`.

`ai-code-agents/claude/claude_desktop_config.json` also exists as a standalone desktop-style config artifact, but the repo's normal setup flow symlinks `settings.json` into `~/.claude/settings.json`.

## What's Included

| Directory | Purpose |
|---|---|
| `agents/` | Subagents — delegated tasks that run in isolated context |
| `commands/` | Slash commands (`/qa`, `/git`, `/smallwins`, etc.) |
| `skills/` | Reusable instruction sets loaded into agent context |
| `CLAUDE.md` | Global instructions loaded into every Claude session |
| `settings.json` | Global settings (effort level, small model, theme) |

## Agents

**Linked agents** (the complete maintained `agents/` directory is linked to `~/.claude/agents/`) — available in every project:
- `orchestrator` — coordination-only delegation map for multi-agent work
- `executor` — general concrete implementation leaf for work no specialist owns
- `backend-architect`, `frontend-developer`, `deployment-engineer`, `test-automator` — specialist implementation/design leaf agents
- `codebase-locator` — finds files/dirs (haiku)
- `codebase-analyzer` — explains how code works (sonnet)
- `context-synthesis` — maps relationships between components (sonnet)
- `antipattern-sniffer` — audits code for smells and bad patterns (sonnet)
- `check` — runs lint, format, test, or typecheck (as requested) and returns a structured pass/fail report (haiku)
- `database-optimizer` — analyzes query plans, indexes, and ORM performance (sonnet)
- `devops-troubleshooter` — investigates incidents and observability gaps (sonnet)
- `performance-engineer` — profiles bottlenecks and optimization targets (sonnet)
- `git-workflow` — git/GitHub workflow only

**Built-in shadows** — same-named definitions that override Claude Code's
built-in agents solely to pin their model. Without these, built-ins inherit
the main session model (expensive). Frontmatter `model:` always wins over
built-ins' defaults, so every agent's tier stays explicit. Do NOT set
`CLAUDE_CODE_SUBAGENT_MODEL` in settings.json — it overrides frontmatter on
*all* agents and flattens the tiers.
- `Explore` — read-only fan-out search (sonnet)
- `general-purpose` — research and multi-step catch-all (sonnet)
- `Plan` — implementation planning, read-only (sonnet)

## Commands

| Command | What it does |
|---|---|
| `/qa` | Code review — cleanliness, idioms, coupling, cohesion |
| `/git` | Safe commit, push, PR, and issue workflows through `git-workflow` |
| `/lint` | Run lint in the check subagent and summarize issues |
| `/prettier` | Run Prettier check mode in the check subagent |
| `/smallwins` | Read-only codebase audit — dead code, naming, lint drift |
| `/ce/pn` | Generate implementation plan from research doc |
| `/ce/ex` | Execute a plan with gated checks and atomic commits |
| `/ce/slop` | Remove AI-generated bloat from diff against main |
| `/ce/cm` | Context compact — summarize state before token limit |
| `/ce/kb-log` | Create a knowledge base entry in `.claude/` |

## Skills

| Skill | What it does |
|---|---|
| `git-workflow` | Safe commit/push/PR lifecycle with pre-hook enforcement |
| `worktree-hygiene` | Git worktree management scripts |
| `codebase-research` | Structure map, symbol index, AST scan scripts |
| `deep-review-workflow` | Autonomous code review + fix workflow |
| `biome-autofix` | Run Biome linter and auto-fix issues |
