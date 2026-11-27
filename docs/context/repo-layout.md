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
- `bin/` holds versioned helper scripts that are run by name, not hooks; `bin/pr-wait` waits in the background for a PR's checks (read-only: `gh pr view`, plus plain `gh api` GETs only with `--review`; a check counts as green only when positively recognised, the verdict comes from counts and never from names; skipped, neutral and expected checks count as green by design). Green must hold on two consecutive polls (late-registering workflows). Opt-in `--review coderabbit` also waits for the bot, done for the current head when: a COMMENTED/APPROVED/CHANGES_REQUESTED review by `coderabbitai` on the head (never DISMISSED/PENDING), the bot's check row (exact name `CodeRabbit`, no workflow, includes skipped) is settled, or its summary comment holds the skip marker and the head's 7-char sha (CodeRabbit edits one summary comment in place per PR and keeps the marker, so the marker alone proves nothing; checked on craft-stack PRs 16 and 17). Comments are read only when checks have settled, with `since`, capped at `PR_WAIT_COMMENT_PAGES`. After `PR_WAIT_REVIEW_GRACE_SECS` (300) from the head's push (earliest check-suite `created_at`, retried while the lookup fails) with nothing for the head it stops waiting: `review=absent` (bot never seen) or `review=absent-for-head`. Each gh call is bounded by `PR_WAIT_CALL_SECS` (60) and the overall timeout; transient gh errors (rate limits honouring Retry-After, 5xx, network) back off (doubling, cap `PR_WAIT_BACKOFF_MAX_SECS`) and give up after `PR_WAIT_OUTAGE_SECS` (600) with three or more in a row; auth (whole `HTTP 401`, a non-rate-limit 403, `gh auth login`), `HTTP 404` and malformed responses stop after three. Nothing links it into a PATH directory yet.

## Work convention
All work happens in a git worktree branched from the default branch, never in the primary checkout. A hook (`local-hooks/worktree-gate.sh`) denies edits and HEAD-changing git commands in a primary checkout.
