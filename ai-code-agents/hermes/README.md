# Hermes

Hermes-ready skills for the Hermes agent. Hermes reads them in place through `skills.external_dirs`, so nothing is copied into `~/.hermes/skills/`.

This section holds skills only. `SOUL.md` and `config.yaml` stay local to each machine (they carry per-machine routing, channels, and credentials) and are not in this repo.

## Layout

```
hermes/
└── skills/<category>/<skill>/SKILL.md
```

Categories follow Hermes's own names (`software-development`, `devops`, `creative`, and so on). Hermes walks the whole tree for `SKILL.md`, so the category folder is organizational only.

## Skills

| Skill | Path under `skills/` | Origin |
|-------|----------------------|--------|
| `wizard` | `software-development/wizard` | claude |
| `grill-with-docs` | `software-development/grill-with-docs` | claude |
| `writing-fragments` | `creative/writing-fragments` | claude |
| `writing-beats` | `creative/writing-beats` | claude |
| `writing-shape` | `creative/writing-shape` | claude |

The `claude` skills originate from the mattpocock-skills repo (MIT, copyright Matt Pocock). The upstream license is included at [`skills/LICENSE-mattpocock-skills`](skills/LICENSE-mattpocock-skills).

Machine-specific or personal skills stay in the local `~/.hermes/skills/` and are not tracked here. A local skill with the same name shadows the external one.

## Wiring

Run the setup script from the repo root. It checks whether Hermes already lists this directory and prints the snippet if not. It never edits `config.yaml`.

```bash
./setup-agent-configs.sh hermes
```

Add this to `~/.hermes/config.yaml`, merged into the existing `skills:` block:

```yaml
skills:
  external_dirs:
    - ~/dfwsc/agents.dfwsc.config/ai-code-agents/hermes/skills
```

Hermes expands `~` and `${VAR}` in `external_dirs`, so `~/...` works. The script prints an absolute path, which also works. Restart Hermes after changing the config.

How Hermes treats this directory:

- External dirs are read-only. Skills Hermes creates still go to `~/.hermes/skills/`.
- A local skill with the same name wins over one from an external dir.
- The scan recurses to any depth and follows directory symlinks, so the category layout is not required.
- Directories named `references`, `templates`, `assets`, and `scripts` inside a skill are support files, not skills.

## Canonical copy and resync

- **claude skills:** canonical source is `../claude/skills/<name>` (in practice a symlink to a local mattpocock-skills checkout). This directory holds real copies, because the symlink targets live outside this repo. After updating the claude copy, resync:

  ```bash
  cp -rL ../claude/skills/wizard skills/software-development/
  cp -rL ../claude/skills/grill-with-docs skills/software-development/
  for s in writing-fragments writing-beats writing-shape; do cp -rL ../claude/skills/$s skills/creative/; done
  ```

Do not copy Hermes-bundled skills (anything in `~/.hermes/skills/.bundled_manifest`) or hub-installed ones (`.hub/lock.json`) into this directory.

## Candidates, need adaptation

Claude skills that could move over but need changes first:

- `brain-locate`, `brain-story-split`: depend on a shared team knowledge base. Keep read-only for a planning-focused agent profile, and never touch rows owned by someone else.
- `worktree-hygiene`: reword for Hermes terminal and kanban worker usage.
- `git-workflow`: drop Claude hook assumptions and the Claude-specific commit trailer rules.
- `wayfinder`, `to-spec`, `to-tickets`, `triage`: need mapping onto Hermes kanban cards instead of Claude plan and task tools.
- `domain-modeling`: check that it does not rely on Claude-only tools or file locations.
- `agent-prompt-builder`: re-aim at Hermes profiles and SOUL files instead of Claude subagent definitions.
- `local-ci`: depends on an external skills checkout; vendor it or document the path.
