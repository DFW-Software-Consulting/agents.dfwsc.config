---
title: Agent Skills
description: Quick-start reference for setting up skills across Claude Code, Codex, and OpenCode
---

# Agent Skills

Reusable instruction sets that extend AI coding agents. All three major terminal agents -- Claude Code, Codex CLI, and OpenCode -- are converging on the [Agent Skills](https://agentskills.io) open standard.

**This is a reference starting point, not a substitute for official documentation.** Each tool evolves rapidly. Read the official docs for your tool before building anything.

## The Common Pattern

Every tool uses the same core structure: a `SKILL.md` file with YAML frontmatter inside a named directory.

```
my-skill/
  SKILL.md              # Required: frontmatter + instructions
  scripts/              # Optional: executable scripts
  references/           # Optional: detailed docs
  assets/               # Optional: images, templates
```

Minimal `SKILL.md`:

```yaml
---
name: my-skill
description: When and why the agent should use this skill
---

Step-by-step instructions the agent follows...
```

The `description` field drives auto-invocation. Write it like a trigger condition, not a marketing blurb.

## Where Skills Go

| Tool        | Project Path                         | Personal/Global Path                    |
|-------------|--------------------------------------|-----------------------------------------|
| Claude Code | `.claude/skills/<name>/SKILL.md`     | `~/.claude/skills/<name>/SKILL.md`      |
| Codex CLI   | `.agents/skills/<name>/SKILL.md`     | `~/.agents/skills/<name>/SKILL.md`      |
| OpenCode    | `.opencode/skills/<name>/SKILL.md`   | `~/.config/opencode/skills/<name>/SKILL.md` |

## Tool-Specific Setup

### Claude Code

Skills replace the older `.claude/commands/` system (which still works as a fallback).

Key extensions beyond the standard:

- `disable-model-invocation: true` -- prevent auto-invocation; user-only
- `allowed-tools: Read, Grep, Glob` -- restrict tool access
- `context: fork` / `agent: Explore` -- run in an isolated subagent
- `` !`command` `` syntax -- inject shell output into skill content
- `$ARGUMENTS`, `$0`, `$1` -- positional argument substitution

Read the docs: <https://code.claude.com/docs/en/skills>

### Codex CLI

Codex relies primarily on `AGENTS.md` files for instructions, with skills as a newer addition.

Key differences:

- Skills live in `.agents/skills/` (not `.codex/`)
- Optional `agents/openai.yaml` for UI metadata and MCP tool dependencies
- Skill discovery walks up from CWD to repo root to `$HOME` to `/etc/codex/skills`
- No tool restriction or subagent fields in frontmatter
- `AGENTS.md` hierarchy: `~/.codex/AGENTS.md` > repo root > subdirectories

Read the docs: <https://developers.openai.com/codex/skills>

### OpenCode

OpenCode has the richest configuration system. Skills are one of seven extension points.

Key differences:

- JSON-first config (`opencode.json`) alongside markdown
- Custom agents (primary + subagent) with per-agent tool/permission control
- Custom commands as markdown files with `$ARGUMENTS` and `` !`command` ``
- Custom tools as TypeScript/JavaScript definitions
- Plugin system with full lifecycle hooks
- Reads `CLAUDE.md` as fallback (disable with `OPENCODE_DISABLE_CLAUDE_CODE=1`)

Read the docs: <https://opencode.ai/docs/rules/>

## Quick Comparison

| Concern                | Claude Code              | Codex CLI                 | OpenCode                        |
|------------------------|--------------------------|---------------------------|---------------------------------|
| Instruction file       | `CLAUDE.md`              | `AGENTS.md`               | `AGENTS.md` (CLAUDE.md fallback)|
| Config format          | YAML frontmatter in MD   | YAML + MD                 | JSON + YAML frontmatter in MD   |
| Global config dir      | `~/.claude/`             | `~/.codex/`               | `~/.config/opencode/`           |
| Custom agents          | `.claude/agents/`        | N/A                       | `.opencode/agents/` or JSON     |
| Custom commands        | Merged into skills       | N/A (AGENTS.md only)      | `.opencode/commands/` or JSON   |
| Tool restrictions      | `allowed-tools` field    | N/A                       | `tools` object per agent        |
| Plugin system          | Yes                      | No                        | Yes (npm + TypeScript)          |
| MCP support            | Yes                      | Yes (openai.yaml)         | Yes (JSON config)               |
| Dynamic shell inject   | `` !`command` ``         | N/A                       | `` !`command` ``                |

## Writing Portable Skills

To write a skill that works across all three tools, stick to the base standard:

1. Use only `name` and `description` in frontmatter
2. Write plain markdown instructions (no tool-specific extensions)
3. Keep the `SKILL.md` focused; put details in `references/`
4. Avoid relying on tool-specific argument substitution syntax

If you need tool-specific behavior, keep the core skill portable and add tool-specific config in separate files (e.g., `agents/openai.yaml` for Codex).

## Before You Build

Each tool has its own quirks, permission model, and evolving feature set. This README gives you the lay of the land, but you need to read the official documentation for whichever tool you are targeting:

| Tool        | Start Here                                                |
|-------------|-----------------------------------------------------------|
| Claude Code | <https://code.claude.com/docs/en/skills>                  |
| Codex CLI   | <https://developers.openai.com/codex/skills>              |
| OpenCode    | <https://opencode.ai/docs/>                               |
| Agent Skills Standard | <https://agentskills.io>                        |

## Current Directory Layout

```
skills/
  README.md                  # This reference guide
```

When you add repository-local skills, place them under `skills/<name>/SKILL.md` using the structure described in "The Common Pattern" above.
