---
description: Creates a new KB entry with proper frontmatter and semantic directory placement
---

# Log KB Entry

Create a structured knowledge base entry in the project's knowledge base directory.

## Standard Directory Structure

```
.opencode/kb/
├── metadata/        — dependency graphs, file classifications, error pattern database
├── code_index/      — function call graphs, type relationships, interface mappings
├── debug_history/   — error-solution pairs indexed by component/error type
├── patterns/        — canonical implementation examples for this codebase
├── cheatsheets/     — quick-reference guides per component with gotchas
├── qa/              — solved problems database with reasoning
└── delta/           — semantic changelogs explaining changes
```

## Frontmatter Template

```yaml
---
title: <Short human-readable title>
link: <stable-slug-for-links>
type: <delta | doc | module>
tags:
  - <area>
  - <symptom>
  - <tool-or-feature>
created_at: <ISO-8601 timestamp>
updated_at: <ISO-8601 timestamp>
uuid: <generated-uuid>
---
```

## Workflow

1. **Determine type** — delta (change log), doc (documentation), or module (code/module info)
2. **Choose directory** — metadata, code_index, debug_history, patterns, cheatsheets, qa, or delta
3. **Create subdirectory if needed** — `mkdir -p .opencode/kb/<directory>`
4. **Generate UUID** — `uuidgen` or `python3 -c "import uuid; print(str(uuid.uuid4()))"`
5. **Generate timestamp** — `date -Iseconds`
6. **Write entry** — create the file with frontmatter followed by content

## Naming Convention
- Use kebab-case for filenames
- Include relevant keywords for searchability
- Keep filenames under 60 characters
