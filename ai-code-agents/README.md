# AI Agent Configuration SOP

Standard Operating Procedure for AI coding agent tooling and workflows.

## What This Repository Contains

All agent configurations are in [`ai-code-agents/`](ai-code-agents/).

## Quick Links

| What you need | Where to find it |
|---------------|------------------|
| Set up Cline (VS Code) | [`ai-code-agents/cline/README.md`](ai-code-agents/cline/README.md) |
| Set up OpenCode | [`ai-code-agents/opencode/README.md`](ai-code-agents/opencode/README.md) |
| Use custom commands | [`ai-code-agents/commands/`](ai-code-agents/commands/) |
| Available skills | [`ai-code-agents/skills/README.md`](ai-code-agents/skills/README.md) |

## Supported Agents

| Tool | What it is | Configuration location |
|------|------------|------------------------|
| **Cline** | VS Code extension with local vLLM | `ai-code-agents/cline/` |
| **OpenCode** | Open-source terminal AI assistant | `ai-code-agents/opencode/` |
| **Claude Code** | Terminal-based AI agent | Uses `ai-code-agents/commands/` and `ai-code-agents/skills/` |

## Quick Setup

### 1. OpenCode Installation

```bash
curl -fsSL https://opencode.ai/install | bash
```

### 2. Cline (VS Code Extension)

1. Install from VS Code Marketplace
2. Configure vLLM backend (see [`ai-code-agents/cline/README.md`](ai-code-agents/cline/README.md)):
   - **API Provider**: OpenAI Compatible
   - **Base URL**: `http://192.168.62.138:9000/v1`
   - **API Key**: `EMPTY` (vLLM default)
   - **Model ID**: `mistralai/Devstral-Small-2-24B-Instruct-2512`

### 3. Skills Setup

All agents use the [Agent Skills](https://agentskills.io) standard:

```yaml
---
name: skill-name
description: When and why to use this skill
---

Step-by-step instructions...
```

| Tool | Skills Path |
|------|-------------|
| Claude Code | `.claude/skills/<name>/SKILL.md` |
| OpenCode | `.opencode/skills/<name>/SKILL.md` |
| Codex CLI | `.agents/skills/<name>/SKILL.md` |

## Workflow Standards

### Code Review (QA Command)

Run structured reviews focused on:
- Cleanliness and readability
- Modern, idiomatic code
- Coupling and cohesion analysis

Usage: `/qa <file-or-directory>`

### Available Skills

| Skill | Purpose |
|-------|---------|
| `biome-linter` | Lint and format with auto-fix |
| `codebase-research` | Map unfamiliar codebases |
| `deep-review-workflow` | Security and bug review |
| `worktree-hygiene` | Git worktree discipline |

## Contributing

When adding new agent configurations:

1. **Place files in `ai-code-agents/`** - Never in the root directory
2. Create dedicated subdirectory for the tool/command/skill
3. Include a README with setup instructions
4. Follow Agent Skills standard for maximum portability
5. Document dependencies and requirements

## Tool Comparison

| Feature | Claude Code | OpenCode | Cline |
|---------|-------------|----------|-------|
| Terminal-based | Yes | Yes | No (VS Code) |
| Local LLM | Yes | Yes | Yes (vLLM) |
| Custom commands | Yes | Yes | Limited |
| Skills system | Yes | Yes | No |
| Plugin ecosystem | Yes | Yes | No |

## Additional Resources

- [Context Engineering for AI Coding Agents](https://www.youtube.com/watch?v=IS_y40zY-hc)
- [Agent Skills Standard](https://agentskills.io)

## Directory Structure

```
ai-code-agents/
├── [cline/](ai-code-agents/cline/)           # Cline VS Code extension setup
├── [commands/](ai-code-agents/commands/)        # Custom slash commands
├── [opencode/](ai-code-agents/opencode/)        # OpenCode configuration
└── [skills/](ai-code-agents/skills/)          # Reusable AI skills and workflows
```

---

**All configurations are in:** [`ai-code-agents/`](ai-code-agents/)

**Main SOP:** See [`../README.md`](../README.md) for the AI-Assisted Development Workflow SOP.
