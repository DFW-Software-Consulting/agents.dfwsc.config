---
description: "Creates a new KB entry with proper frontmatter and semantic directory placement"
---
# Log KB Entry

Create a structured knowledge base entry in the project's `.claude/` directory.

This command is invoked from within a project. The `.claude/` directory refers to the current project's directory, not this config directory.

## Standard Directory Structure

```
.claude/
├── metadata/        — dependency graphs, file classifications, error pattern database
├── code_index/      — function call graphs, type relationships, interface mappings
├── debug_history/   — error-solution pairs indexed by component/error type
├── patterns/        — canonical implementation examples for this codebase
├── cheatsheets/     — quick-reference guides per component with gotchas
├── qa/              — solved problems database with reasoning
└── delta/           — semantic changelogs explaining changes
```

## Frontmatter Template

```
---
title: <Short human-readable title>
link: <stable-slug-for-links>
type: <delta | doc | module>
path: <relative path, for modules/docs>
depth: <nesting level, 0 = root>
seams: <[A] architecture | [E] entry | [M] module | [S] state | [D] data>
ontological_relations:
  - relates_to: [[<primary-system-or-area>]]
  - affects: [[<component-or-module>]]
  - fixes: [[<bug-or-failure-mode>]]
tags:
  - <area>
  - <symptom>
  - <tool-or-feature>
created_at: <ISO-8601 timestamp>
updated_at: <ISO-8601 timestamp>
uuid: <generated-uuid>
---
```

## Semantic Directory Selection

Choose the most semantically correct directory under `.claude/` (the user's project, not this config dir):

| Directory | Purpose |
|-----------|---------|
| `metadata/` | Dependency graphs, file classifications, error pattern database |
| `code_index/` | Function call graphs, type relationships, interface mappings |
| `debug_history/` | Error-solution pairs indexed by component/error type |
| `patterns/` | Canonical implementation examples |
| `cheatsheets/` | Quick-reference guides per component with gotchas |
| `qa/` | Solved problems database with reasoning |
| `delta/` | Semantic changelogs explaining changes |

## Workflow

1. **Determine type** — delta (change log), doc (documentation), or module (code/module info)
2. **Choose directory** — based on content purpose from the directory table above
3. **Create subdirectory if needed** — `mkdir -p .claude/<directory>` in the project root
4. **Generate UUID** — use `uuidgen` or Python: `python3 -c "import uuid; print(str(uuid.uuid4()))"`
5. **Generate timestamp** — ISO-8601 format: `date -Iseconds` (or `python3 -c "from datetime import datetime; print(datetime.utcnow().isoformat() + 'Z')"` for UTC)
6. **Write entry** — create the file with frontmatter followed by content

## Example

For a debugging session about a Python import error:

**File:** `.claude/debug_history/import-error-resolution.md`

```yaml
---
title: Python ImportError Resolution for Circular Dependencies
link: py-import-error-circular-deps
type: delta
path: debug_history/
depth: 1
seams: [D]
ontological_relations:
  - relates_to: [[Python]]
  - affects: [[import-system]]
  - fixes: [[CircularDependencyError]]
tags:
  - python
  - import-error
  - circular-dependency
created_at: 2024-01-15T10:30:00Z
updated_at: 2024-01-15T10:30:00Z
uuid: a1b2c3d4-e5f6-7890-abcd-ef1234567890
---

## Problem

ImportError when importing `module_a` from `module_b` and vice versa.

## Root Cause

Circular import chain between `module_a.py` and `module_b.py`.

## Solution

1. Move shared imports to a third module
2. Use `TYPE_CHECKING` guard for type-only imports
3. Defer imports inside functions when needed

## Reference

- Python docs: [importlib](https://docs.python.org/3/library/importlib.html)
```

## Naming Convention

- Use kebab-case for filenames
- Include relevant keywords for searchability
- Keep filenames under 60 characters
