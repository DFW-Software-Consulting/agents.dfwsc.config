# Codex Configuration

This directory contains DFWSC Codex setup material using Codex-native locations.

## Layout

| Path | Installed location | Purpose |
|------|--------------------|---------|
| `AGENTS.md` | `~/.codex/AGENTS.md` | Global Codex instructions |
| `config.toml` | `~/.codex/config.toml` | Global Codex defaults |
| `agents/*.toml` | `~/.codex/agents/*.toml` | Custom Codex subagents |
| `prompts/*.md` | `~/.codex/prompts/*.md` | Codex custom slash prompts |
| `skills/*/SKILL.md` | `~/.agents/skills/*/SKILL.md` | Shared Agent Skills |
| `commands/` | Not linked by default | Mirrored Claude/OpenCode command source layout |

## Setup

From the repository root:

```bash
./setup-agent-configs.sh codex
```

Or include it with the other tools:

```bash
./setup-agent-configs.sh all
```

Restart Codex after changing linked config, agent, prompt, or skill files.

The setup script refuses to replace existing real directories; move them aside manually if you want the maintained `agents/` or `prompts/` directories linked.

## Custom Commands

Codex custom commands are implemented as custom prompts under `prompts/`.
Codex scans only top-level Markdown files in `~/.codex/prompts`, so nested
Claude/OpenCode commands from `commands/ce/` are flattened as `ce-*.md`.

Examples:

```text
/prompts:qa src/app
/prompts:ce-pn memory-bank/research/example.md
/prompts:plannotator-review
```

The `commands/` directory is kept as a source-compatible mirror of the
Claude/OpenCode command breakdown.

## Skills

Codex reads shared skills from `~/.agents/skills` and repo-scoped skills from
`.agents/skills`. This setup links the shared DFWSC skills into
`~/.agents/skills` so they are available across repositories.

## Notes

- Project-specific Codex config can also live in a repo at `.codex/config.toml`.
- Project-specific instructions should use `AGENTS.md` at the repository root or in nested directories.
- Provider and auth settings are intentionally not hard-coded here. Private/local endpoints are deployment examples, not universal defaults.
