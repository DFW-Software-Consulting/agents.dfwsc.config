# DFWSC AI Agent Configs

This directory contains DFWSC configuration and setup material for the AI coding tools used in daily development.

## Quick Links

| What you need | Where to find it |
|---------------|------------------|
| Cline setup (VS Code) | [`cline/README.md`](cline/README.md) |
| OpenCode config files | [`opencode/`](opencode/) |
| OpenCode subagents | [`opencode/agents/README.md`](opencode/agents/README.md) |
| Claude config files | [`claude/`](claude/) |
| Codex config files | [`codex/`](codex/) |
| Gemini config files | [`gemini/`](gemini/) |
| Qwen config files | [`qwen/`](qwen/) |
| Skills reference | [`skills/README.md`](skills/README.md) |

## Supported Agents

| Tool | What it is | Configuration location |
|------|------------|------------------------|
| **Cline** | VS Code extension with local vLLM | `cline/` |
| **OpenCode** | Terminal AI assistant | `opencode/` |
| **Claude Code** | Terminal AI agent | `claude/` |
| **Codex** | Terminal, IDE, and app coding agent | `codex/` |
| **Gemini CLI** | Terminal AI agent (Google) | `gemini/` |
| **Qwen** | Terminal AI assistant (via OpenCode) | `qwen/` |

## Quick Setup

Clone this repo, then run the setup script from the repo root to symlink local tool config back to the checked-out files:

```bash
# Claude Code + OpenCode + Codex config, OpenCode helper deps, and Plannotator CLI
./setup-agent-configs.sh all

# Or set up one piece at a time
./setup-agent-configs.sh claude
./setup-agent-configs.sh opencode
./setup-agent-configs.sh codex
./setup-agent-configs.sh plannotator
```

The script does not install Claude Code or OpenCode themselves. Install the tools you use first, then run the setup script.

### 1. OpenCode Installation

```bash
curl -fsSL https://opencode.ai/install | bash
```

### 2. Claude Code Installation

Install Claude Code separately, then run:

```bash
./setup-agent-configs.sh claude
```

### 3. Cline (VS Code Extension)

1. Install from VS Code Marketplace
2. Configure vLLM backend (see [`cline/README.md`](cline/README.md)):
   - **API Provider**: OpenAI Compatible
   - **Base URL**: `http://192.168.62.138:9000/v1`
   - **API Key**: `EMPTY` (vLLM default)
   - **Model ID**: `mistralai/Devstral-Small-2-24B-Instruct-2512`

### 4. Codex

Install Codex separately, then run:

```bash
./setup-agent-configs.sh codex
```

This links global instructions, config defaults, custom subagents, custom prompts, and shared skills.

### 5. Skills Setup

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
| Gemini CLI | `.gemini/skills/<name>/SKILL.md` |
| Qwen | `.qwen/skills/<name>/SKILL.md` |
| Codex CLI | `.agents/skills/<name>/SKILL.md` |

## Workflow Standards

### Code Review (QA Command)

Run structured reviews focused on:
- Cleanliness and readability
- Modern, idiomatic code
- Coupling and cohesion analysis

Usage: `/qa <file-or-directory>`

### Available Skills

See [`skills/README.md`](skills/README.md) for skill structure, cross-tool compatibility notes, and setup guidance.

## Contributing

When adding new agent configurations:

1. **Place files in `ai-code-agents/`** - Never in the root directory
2. Create dedicated subdirectory for the tool/command/skill
3. Include a README with setup instructions
4. Follow Agent Skills standard for maximum portability
5. Document dependencies and requirements

## Tool Comparison

| Feature | Claude Code | OpenCode | Cline | Gemini CLI | Qwen |
||---------|-------------|----------|-------|------------|------|
| Terminal-based | Yes | Yes | No (VS Code) | Yes | Yes |
| Local LLM | Yes | Yes | Yes (vLLM) | No | Yes |
| Custom commands | Yes | Yes | Limited | Yes | Yes |
| Skills system | Yes | Yes | No | Yes | Yes |
| Plugin ecosystem | Yes | Yes | No | Yes | No |

## Additional Resources

- [Context Engineering for AI Coding Agents](https://www.youtube.com/watch?v=IS_y40zY-hc)
- [Agent Skills Standard](https://agentskills.io)

## Directory Structure

```
ai-code-agents/
├── [claude/](claude/)        # Claude Code local config and assets
├── [cline/](cline/)          # Cline VS Code extension setup
├── [codex/](codex/)          # Codex config, agents, prompts, and skills
├── [gemini/](gemini/)        # Gemini CLI config and assets
├── [opencode/](opencode/)    # OpenCode configuration files
├── [qwen/](qwen/)            # Qwen config and assets
└── [skills/](skills/)        # Skill authoring and portability reference
```

---

**All configurations are in:** [`ai-code-agents/`](.)

**Main SOP:** See [`../README.md`](../README.md) for the AI-Assisted Development Workflow SOP.
