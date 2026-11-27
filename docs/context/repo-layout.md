# Repository layout

Central home for coding-agent configuration, engineering standards and workflow templates. The repository is public: do not commit hostnames, addresses, emails or machine names.

## Top level
- `ai-code-agents/` : per-tool configuration (below).
- `engineering-principles/` : the SOP and the work issue and PR templates.
- `setup-agent-configs.sh` : creates symlinks from a tool's config directory to files in this repository. Targets: claude, claude-personal, opencode, codex, gemini, hermes, plannotator, all (all does not link gemini).
- OpenCode's `global.opencode.json` takes infrastructure values from environment variables (`{env:SUPABASE_MCP_PROJECT_REF}`, `{env:BRAIN_MCP_URL}`, `{env:SUPABASE_ACCESS_TOKEN}`) instead of literals; `claude/settings.json` uses `<your-project-ref>`-style placeholders in its prose. Real identifiers are never committed; the same goes for the private schema card read by brain-schema-hint. The brain-locate skill (Claude and Codex copies) reads the Brain project reference from the `PROJECT_REFS` line of the private `~/.claude/shared-db-gate.conf` and stops when it is missing.
- `opencode.json`, `README.md` : an OpenCode config file and the repo overview.

## ai-code-agents/
- `claude/` : Claude Code config: `CLAUDE.md`, `settings.json`, `agents/`, `commands/`, `skills/`, `hooks/`, `local-hooks/`, `personal-hooks/`, `claude_desktop_config.json`.
- `opencode/` : `global.opencode.json`, `opencode.json`, `agents/`, `commands/`, `skills/`, `tools/`.
- `codex/` : `AGENTS.md`, `config.toml`, `agents/`, `commands/`, `prompts/`, `skills/`.
- `gemini/` : `GEMINI.md`, `agents/`, `commands/`, `skills/`.
- `cline/` : `README.md`, `commands/`, `skills/`.
- `hermes/` : `README.md` and `skills/` only.
- `skills/` : a README on shared skills.
- Each tool directory under `ai-code-agents/` (claude, opencode, codex, gemini, cline, hermes) and `skills/` has a `README.md` with that tool's setup steps; read it before changing the tool's config.

## What the setup script links
- `claude` links `CLAUDE.md` (a short pointer note only; personal global instructions are private and not versioned here), `settings.json`, `agents`, `commands` and `skills` from `ai-code-agents/claude/` into `~/.claude/`.
- `claude-personal` links `agents`, `commands` and `skills` into `~/.claude-personal/`.
- `opencode`, `codex` and `gemini` link their own files into the matching tool directories.
- `hermes` links nothing; it prints the `skills.external_dirs` entry to add.
- The script refuses to replace an existing real directory.
- Live sessions read these from the main worktree through whole-directory links (hooks-shipping.md), not from the primary checkout.
- It does not link `hooks/`, `local-hooks/` or `personal-hooks/`. How those reach a live session is in hooks-shipping.md.

## Claude directory notes
- `agents/` includes same-named shadows of built-in agents (for example `Explore`, `Plan`, `general-purpose`).
- `skills/` holds one directory per skill, each with a `SKILL.md`. `skills/context-docs/SKILL.md` defines the `docs/context/` convention; `skills/git-verify/SKILL.md` runs `local-hooks/run-checks.sh`.
- `commands/` holds slash commands. Command headers use `allowed-tools`, which pre-approves tools and does not restrict them (see errors.md).
- `bin/` holds versioned helper scripts run by name, not hooks; `bin/wt-reap` reports which git worktrees are safe to remove (report-only by default; `--apply` never forces; only dependency and tool caches (`node_modules`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.gradle`, and `venv`/`.venv` holding `pyvenv.cfg`) are dropped without reading their files, any other ignored file, build outputs such as `dist` and `build` included, keeps the worktree unless `--include-ignored` (which lists the files first), secret-looking names (`.env*`, `*.env`, `.envrc`, `secrets.*`, `*secret*.json`, `*.tfstate*`, `.npmrc`, `.pypirc`, `.netrc`, `.git-credentials`, `*.pem`, `*.key`, `id_*`, `*.p12`, `*.keystore`, `credentials*`) keep it always (caches are searched by name only), an unreadable directory keeps it, and the ignored files are judged again just before each removal; it keeps worktrees whose index has assume-unchanged or skip-worktree flags, and counts only pull requests merged into the default branch, which needs `origin/HEAD` set as a symbolic ref) and needs `git` and `gh`. Nothing links it into a PATH directory yet (the `worktree-hygiene` skill's installer does not install it either; link it by hand). It replaces the retired `wt-cleanup` helper, which forced removals and is no longer shipped or installed by that skill. The cline, codex, gemini and opencode copies of the `worktree-hygiene` skill (`ai-code-agents/<harness>/skills/worktree-hygiene/`) still ship the old `wt-cleanup.sh` (uses `--force` and `-D`); they are not changed by the wt-reap work and are tracked here for a follow-up.

## Work convention
All work happens in a git worktree branched from the default branch, never in the primary checkout. A hook (`local-hooks/worktree-gate.sh`) denies edits and HEAD-changing git commands in a primary checkout.
