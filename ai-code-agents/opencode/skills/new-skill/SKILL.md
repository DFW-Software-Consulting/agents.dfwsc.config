---
name: new-skill
description: Use when asked to create a new skill, add a skill, or scaffold a skill for any agent tool. Takes a skill name and description as input.
---

# New Skill Scaffold

Create a new reusable skill and mirror it across all configured agent tools.

## Input

- `$ARGUMENTS` — skill name and a short description of what it does
  - Example: `code-review Reviews code for security and performance issues`

## Steps

### 1. Parse Input

- First word of `$ARGUMENTS` = skill name (kebab-case)
- Remaining words = description

### 2. Ask Clarifying Questions (if not obvious)

- Which tools to target? (default: opencode, claude, gemini — all three)
- Should it be read-only or can it make edits?
- Does it need any supporting scripts?

### 3. Create the Skill Directory and SKILL.md

For each target tool, create:

```
ai-code-agents/<tool>/skills/<skill-name>/SKILL.md
```

The `SKILL.md` must follow this structure:

```markdown
---
name: <skill-name>
description: <one-line trigger condition — write it like "Use when..." not a marketing blurb>
---

# <Skill Title>

<Brief explanation of what this skill does and when to use it.>

## Steps

1. <Step one>
2. <Step two>
...

## Output

<What the skill produces — a report, files, a commit, etc.>

## Rules

- <Any hard constraints — e.g. "never edit files", "always confirm before deleting">
```

### 4. Update the Skills Table

Add a row to `ai-code-agents/skills/README.md` in the "Current Skills" table:

```
| `<skill-name>` | <description> | <tools> |
```

### 5. Summary

Report:
- Files created (with paths)
- Which tools the skill was added to
- How to invoke it
