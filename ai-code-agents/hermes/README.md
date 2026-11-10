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
| `writing-fragments` | `creative/writing-fragments` | claude |
| `writing-beats` | `creative/writing-beats` | claude |
| `writing-shape` | `creative/writing-shape` | claude |
| `grilling` | `productivity/grilling` | mattpocock-skills |

Each skill's `agents/openai.yaml` is upstream metadata that Hermes ignores. The `writing-*` skills are marked in-progress upstream.

The `claude` and `mattpocock-skills` skills originate from the mattpocock-skills repo (MIT, copyright Matt Pocock). The upstream license is included at [`skills/LICENSE-mattpocock-skills`](skills/LICENSE-mattpocock-skills).

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
  cd ai-code-agents/hermes
  rm -rf skills/software-development/wizard && cp -rL ../claude/skills/wizard skills/software-development/
  for s in writing-fragments writing-beats writing-shape; do rm -rf "skills/creative/$s" && cp -rL "../claude/skills/$s" skills/creative/; done
  ```

- **mattpocock-skills skills:** `grilling` is not in `../claude/skills`. Its canonical source is `skills/productivity/grilling` in a local mattpocock-skills checkout. Resync from that checkout (set `MATTPOCOCK` to its path):

  ```bash
  cd ai-code-agents/hermes
  rm -rf skills/productivity/grilling && mkdir -p skills/productivity && cp -rL "$MATTPOCOCK/skills/productivity/grilling" skills/productivity/
  ```

Do not copy Hermes-bundled skills (anything in `~/.hermes/skills/.bundled_manifest`) or hub-installed ones (`.hub/lock.json`) into this directory.

## Candidates, need adaptation

Claude skills that could move over but need changes first:

- `brain-locate`, `brain-story-split`: depend on a shared team knowledge base. Keep read-only for a planning-focused agent profile, and never touch rows owned by someone else.
- `worktree-hygiene`: reword for Hermes terminal and kanban worker usage.
- `git-workflow`: drop Claude hook assumptions and the Claude-specific commit trailer rules.
- `wayfinder`, `to-spec`, `to-tickets`, `triage`: need mapping onto Hermes kanban cards instead of Claude plan and task tools.
- `grill-with-docs`: depends on upstream `grilling` (now included) and `domain-modeling` (vendor it to enable this), and it writes ADRs/glossary into a repo.
- `domain-modeling`: check that it does not rely on Claude-only tools or file locations.
- `agent-prompt-builder`: re-aim at Hermes profiles and SOUL files instead of Claude subagent definitions.
- `local-ci`: depends on an external skills checkout; vendor it or document the path.
