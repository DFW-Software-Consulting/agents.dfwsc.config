# OpenCode Config

Configuration for [OpenCode](https://opencode.ai) — terminal AI assistant.

## Setup (New Machine)

From the repo root, link OpenCode config into `~/.config/opencode/`:

```bash
./setup-agent-configs.sh opencode

# Optional: install the Plannotator CLI used by the configured plugin/commands
./setup-agent-configs.sh plannotator
```

Manual equivalent:

```bash
mkdir -p ~/.config/opencode
mkdir -p ~/.config/opencode/tools

# Global config (model, providers, agent model assignments)
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/opencode/global.opencode.json ~/.config/opencode/opencode.json
ln -sfn ~/dfwsc/agents.dfwsc.config/ai-code-agents/opencode/agents ~/.config/opencode/agents
ln -sfn ~/dfwsc/agents.dfwsc.config/ai-code-agents/opencode/commands ~/.config/opencode/commands
ln -sfn ~/dfwsc/agents.dfwsc.config/ai-code-agents/opencode/skills ~/.config/opencode/skills

# Read-only DB wrapper for working mode
ln -sf ~/dfwsc/agents.dfwsc.config/ai-code-agents/opencode/tools/db-readonly.mjs ~/.config/opencode/tools/db-readonly.mjs
npm install --prefix ~/.config/opencode better-sqlite3 pg mysql2 mssql
```

Add your API keys to your shell profile:
```bash
export OPENROUTER_API_KEY=your-key-here
# For OpenCode Zen models, run /connect inside OpenCode
```

## What's Included

| Directory/File | Purpose |
|---|---|
| `agents/` | Subagents with per-agent model assignments |
| `commands/` | Slash commands (`/qa`, `/git`, `/smallwins`, etc.) |
| `skills/` | Reusable instruction sets |
| `tools/` | Local utility scripts, including the read-only DB wrapper |
| `global.opencode.json` | Global config — symlink to `~/.config/opencode/opencode.json` |
| `opencode.json` | Project-level config with agent model assignments |

## Model Strategy

| Agent group | Model |
|---|---|
| Default (main) | `opencode/minimax-m2.5-free` (Zen free) |
| Research agents (read-only) | `opencode/minimax-m2.7` |
| Specialist agents | `opencode/gpt-5.3-codex` |
| `/git` git-runner / typecheck / test-runner | `opencode/minimax-m2.5-free` |

## Agents

See [agents/README.md](agents/README.md) for the full list and when to use each one.

## Additional Resources

- [awesome-opencode](https://github.com/awesome-opencode/awesome-opencode) — curated list of OpenCode plugins, skills, agents, and community resources
- [plannotator](https://plannotator.ai) — visual plan review UI (already configured as a plugin)
- [OpenCode docs](https://opencode.ai/docs)

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
| `new-skill` | Scaffold a new skill across all tools |
