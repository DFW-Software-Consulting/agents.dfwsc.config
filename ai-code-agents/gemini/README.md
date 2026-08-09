# Gemini CLI Config

Configuration for [Gemini CLI](https://github.com/google-gemini/gemini-cli) — Google's terminal AI agent.

## Setup (New Machine)

```bash
./setup-agent-configs.sh gemini
```

This links `GEMINI.md`, `agents/`, and `commands/` into `~/.gemini/`, and links the shared Agent Skills source `ai-code-agents/codex/skills` to `~/.agents/skills`. The `all` setup target does not include Gemini, so existing real Gemini directories are not silently replaced.

## What's Included

| Directory | Purpose |
|---|---|
| `agents/` | Local agents with tool definitions |
| `commands/` | Gemini TOML slash commands (`/qa`, `/git`, `/smallwins`, etc.) |
| shared `~/.agents/skills` | Reusable instruction sets |
| `GEMINI.md` | Global instructions loaded into every Gemini session |

## Agents

13 local agents mirrored behaviorally from the maintained lineup and adapted to Gemini frontmatter (`kind: local`, `tools` list). Gemini has no orchestrator in this setup.

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
| `/ce:prompt` | Build an agent prompt and save it to `memory-bank/prompt/` |
| `/ce:QA` | Read-only post-execution QA review |
| `/ce:slop` | Remove AI-generated bloat from diff against main |
| `/ce:cm` | Context compact — summarize state before token limit |
| `/ce:kb-log` | Create a knowledge base entry |
| `/ce:rr` | Read-only codebase research synthesis |

## Skills

Gemini should use shared skills from `~/.agents/skills`; this repository does not install a separate `~/.gemini/skills` mirror.
