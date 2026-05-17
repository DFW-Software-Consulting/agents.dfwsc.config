# Gemini CLI Config

Configuration for [Gemini CLI](https://github.com/google-gemini/gemini-cli) — Google's terminal AI agent.

## Setup (New Machine)

```bash
mkdir -p ~/.gemini/agents

# Global instructions
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/gemini/GEMINI.md ~/.gemini/GEMINI.md
```

## What's Included

| Directory | Purpose |
|---|---|
| `agents/` | Local agents with tool definitions |
| `commands/` | Slash commands (`/qa`, `/git`, `/smallwins`, etc.) |
| `skills/` | Reusable instruction sets |
| `GEMINI.md` | Global instructions loaded into every Gemini session |

## Agents

13 agents mirrored from Claude — same behavior, adapted frontmatter for Gemini's format (`kind: local`, `tools` list).

**Research agents** (read-only):
- `codebase-locator`, `codebase-analyzer`, `context-synthesis`, `antipattern-sniffer`

**Specialist agents**:
- `backend-architect`, `frontend-developer`, `cloud-architect`, `database-optimizer`, `test-automator`, `devops-troubleshooter`, `deployment-engineer`, `mobile-developer`, `performance-engineer`

## Commands

| Command | What it does |
|---|---|
| `/qa` | Code review — cleanliness, idioms, coupling, cohesion |
| `/git` | Safe commit, push, PR, and issue workflows through `git-workflow` |
| `/smallwins` | Read-only codebase audit — dead code, naming, lint drift |
| `/ce/pn` | Generate implementation plan from research doc |
| `/ce/ex` | Execute a plan with gated checks and atomic commits |
| `/ce/slop` | Remove AI-generated bloat from diff against main |
| `/ce/cm` | Context compact — summarize state before token limit |
| `/ce/kb-log` | Create a knowledge base entry |

## Skills

| Skill | What it does |
|---|---|
| `git-workflow` | Safe commit/push/PR lifecycle with pre-hook enforcement |
| `worktree-hygiene` | Git worktree management scripts |
| `codebase-research` | Structure map, symbol index, AST scan scripts |
| `deep-review-workflow` | Autonomous code review + fix workflow |
| `biome-autofix` | Run Biome linter and auto-fix issues |
