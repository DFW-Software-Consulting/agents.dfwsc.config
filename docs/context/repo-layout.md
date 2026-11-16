# Repository layout

Central home for coding-agent configuration, engineering standards and workflow templates. The repository is public: do not commit hostnames, addresses, emails or machine names.

## Top level
- `ai-code-agents/` : per-tool configuration (below).
- `engineering-principles/` : the SOP and the work issue and PR templates.
- `setup-agent-configs.sh` : creates symlinks from a tool's config directory to files in this repository. Targets: claude, claude-personal, opencode, codex, gemini, hermes, plannotator, all (all does not link gemini).
- `opencode.json`, `README.md` : repo-level config and overview.

## ai-code-agents/
- `claude/` : Claude Code config: `CLAUDE.md`, `settings.json`, `agents/`, `commands/`, `skills/`, `hooks/`, `local-hooks/`, `personal-hooks/`, `claude_desktop_config.json`.
- `opencode/` : `global.opencode.json`, `opencode.json`, `agents/`, `commands/`, `skills/`, `tools/`.
- `codex/` : `AGENTS.md`, `config.toml`, `agents/`, `commands/`, `prompts/`, `skills/`.
- `gemini/` : `GEMINI.md`, `agents/`, `commands/`, `skills/`.
- `cline/` : `README.md`, `commands/`, `skills/`.
- `hermes/` : `README.md` and `skills/` only.
- `skills/` : a README on shared skills.

## What the setup script links
- `claude` links `CLAUDE.md`, `settings.json`, `agents`, `commands` and `skills` from `ai-code-agents/claude/` into `~/.claude/`.
- `claude-personal` links `agents`, `commands` and `skills` into `~/.claude-personal/`.
- `opencode`, `codex` and `gemini` link their own files into the matching tool directories.
- `hermes` links nothing; it prints the `skills.external_dirs` entry to add.
- The script refuses to replace an existing real directory.
- It does not link `hooks/`, `local-hooks/` or `personal-hooks/`. How those reach a live session is in hooks-shipping.md.

## Claude directory notes
- `agents/` includes same-named shadows of built-in agents (for example `Explore`, `Plan`, `general-purpose`).
- `skills/context-docs/SKILL.md` defines the `docs/context/` convention this directory follows.
- `commands/` holds slash commands. Command headers use `allowed-tools`, which pre-approves tools and does not restrict them (see errors.md).

## Work convention
All work happens in a git worktree branched from the default branch, never in the primary checkout. A hook (`local-hooks/worktree-gate.sh`) denies edits and HEAD-changing git commands in a primary checkout.
