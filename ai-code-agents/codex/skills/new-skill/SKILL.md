---
name: new-skill
description: Use when creating, scaffolding, or mirroring reusable agent skills across OpenCode, Claude Code, and Agent Skills-compatible locations.
---

# New Skill Scaffold

Create a reusable agent skill with valid portable frontmatter, concise instructions, and tool-specific extensions only when they are needed.

## Inputs

- Expected `$ARGUMENTS` format: `<skill-name> <description>`
- Example: `code-review Use when reviewing code for security, correctness, and maintainability issues.`
- The first token is the skill name. All remaining text is the skill description.
- If the user provides separate fields, use `name` as the skill name and `description` as the skill description.

## Name Rules

Validate before writing files:

- Must match `^[a-z0-9]+(-[a-z0-9]+)*$`.
- Must be 1-64 characters.
- Use lowercase alphanumeric words separated by single hyphens.
- No leading hyphen, trailing hyphen, consecutive hyphens, spaces, underscores, or uppercase letters.
- Directory name must exactly match the frontmatter `name`.

## Clarifying Questions

Ask only when the input is ambiguous or would cause an invalid or unsafe scaffold.

- Ask for a valid name if the name is missing or fails validation.
- Ask for a specific trigger condition if the description is missing, vague, or not written as a usage condition.
- Ask which target locations to create only when the user's scope is unclear. Otherwise mirror to the repository paths that exist for the requested tool family.
- Ask before adding side-effect automation for deploy, publish, commit, push, destructive file operations, external service changes, or credential use.

## Target Paths

Create or update `SKILL.md` in the requested tool locations.

Project-local runtime paths:

```text
.opencode/skills/<skill-name>/SKILL.md
.claude/skills/<skill-name>/SKILL.md
.agents/skills/<skill-name>/SKILL.md
```

Global or personal runtime paths:

```text
~/.config/opencode/skills/<skill-name>/SKILL.md
~/.claude/skills/<skill-name>/SKILL.md
~/.agents/skills/<skill-name>/SKILL.md
```

Repository mirror paths in this config repo:

```
ai-code-agents/<tool>/skills/<skill-name>/SKILL.md
```

Use the repository mirror path when maintaining checked-in skill templates. Example tool names include `opencode`, `claude`, and any Agent Skills-compatible tool directory already present in the repo.

## Portable Template

Use only `name` and `description` in frontmatter unless a target tool requires more. This is the most portable baseline across OpenCode, Claude Code, and Agent Skills-compatible consumers.

```markdown
---
name: <skill-name>
description: Use when <specific trigger condition and task outcome>.
---

# <Skill Title>

<One short paragraph explaining what this skill does and when to use it.>

## Inputs

- `<input-name>`: <expected format, defaults, and constraints>

## Steps

1. <Concrete action>
2. <Concrete action>
3. <Concrete action>

## Supporting Files

- Put long references in `references/`.
- Put examples in `examples/`.
- Put executable helpers in `scripts/`.

## Output

<What the skill produces: files changed, report, command output, PR, issue, etc.>

## Rules

- <Hard constraints, safety rules, and confirmation requirements>
```

## Tool-Specific Frontmatter

OpenCode recognizes `name`, `description`, `license`, `compatibility`, and `metadata`. Keep OpenCode skill frontmatter to `name` and `description` unless there is a concrete need for the optional fields.

Claude Code supports additional frontmatter such as `disable-model-invocation`, `user-invocable`, `argument-hint`, `arguments`, `allowed-tools`, `model`, `effort`, and `context`. Use Claude-only fields only in Claude-specific skill files or when portability is not required.

For side-effect workflows such as deploy, release, publish, commit, push, destructive cleanup, data migration, or external service mutation, prefer manual invocation controls where supported. For Claude Code, add:

```yaml
disable-model-invocation: true
```

Also document required confirmation steps in the skill body.

## Supporting Files

Keep `SKILL.md` concise. Move material that is long, reusable, or tool-like into files next to `SKILL.md`:

- `references/`: detailed docs, checklists, policies, schemas, long explanations.
- `examples/`: sample inputs, outputs, fixtures, before/after snippets.
- `scripts/`: executable helpers used by the skill. Document required runtime, arguments, and safety constraints.

Reference supporting files by relative path from the skill directory.

## Repository README

When adding a repository-maintained skill, update `ai-code-agents/skills/README.md` if the Current Skills table is missing the new skill:

```
| `<skill-name>` | <purpose> | <tools> |
```

Keep the row consistent with the existing table style.

## Verification Checklist

- `SKILL.md` exists at each intended target path.
- Directory name and frontmatter `name` match exactly.
- Name passes `^[a-z0-9]+(-[a-z0-9]+)*$` and is 1-64 characters.
- Description is 1-1024 characters, starts with `Use when`, and states a specific trigger condition.
- Portable skills use only `name` and `description` frontmatter.
- Tool-specific frontmatter is isolated to tool-specific mirrors and documented in the skill body.
- Supporting files are referenced correctly and kept next to `SKILL.md`.
- Side-effect workflows require manual invocation or explicit confirmation where appropriate.
- README table is updated when this repo gains a maintained skill.

## Final Report

Report:

- Files created (with paths)
- Files changed (with paths)
- Target tools and runtime locations covered
- Supporting files added, if any
- Any tool-specific frontmatter used and why
- Verification performed
