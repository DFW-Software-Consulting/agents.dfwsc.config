# Claude Code Config

Configuration for [Claude Code](https://claude.ai/code) — Anthropic's terminal AI agent.

## Setup (New Machine)

```bash
mkdir -p ~/.claude/agents

# Global instructions and settings
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/CLAUDE.md ~/.claude/CLAUDE.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/settings.json ~/.claude/settings.json

# Global subagents
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/codebase-locator.md ~/.claude/agents/codebase-locator.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/codebase-analyzer.md ~/.claude/agents/codebase-analyzer.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/context-synthesis.md ~/.claude/agents/context-synthesis.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/antipattern-sniffer.md ~/.claude/agents/antipattern-sniffer.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/typecheck.md ~/.claude/agents/typecheck.md
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/claude/agents/test-runner.md ~/.claude/agents/test-runner.md
```

Specialist agents (`backend-architect`, `cloud-architect`, etc.) are best copied per-project into `.claude/agents/` rather than linked globally.

## What's Included

| Directory | Purpose |
|---|---|
| `agents/` | Subagents — delegated tasks that run in isolated context |
| `commands/` | Slash commands (`/qa`, `/smart-git`, `/smallwins`, etc.) |
| `skills/` | Reusable instruction sets loaded into agent context |
| `CLAUDE.md` | Global instructions loaded into every Claude session |
| `settings.json` | Global settings (effort level, small model, theme) |

## Agents

See [agents/README.md](agents/README.md) for the full list and when to use each one.

**Global agents** (link to `~/.claude/agents/`) — available in every project:
- `codebase-locator` — finds files/dirs (haiku)
- `codebase-analyzer` — explains how code works (haiku)
- `context-synthesis` — maps relationships between components (haiku)
- `antipattern-sniffer` — audits code for smells and bad patterns (haiku)
- `typecheck` — runs typecheck and returns structured error report (haiku)
- `test-runner` — runs tests and returns structured result report (haiku)

**Specialist agents** (copy per-project into `.claude/agents/`):
- `backend-architect`, `frontend-developer`, `cloud-architect`, `database-optimizer`, `test-automator`, `devops-troubleshooter`, `deployment-engineer`, `mobile-developer`, `performance-engineer`

## Commands

| Command | What it does |
|---|---|
| `/qa` | Code review — cleanliness, idioms, coupling, cohesion |
| `/smart-git` | Safe add → commit → push with branch health checks |
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
