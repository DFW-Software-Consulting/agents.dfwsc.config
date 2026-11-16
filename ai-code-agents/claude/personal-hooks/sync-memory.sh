#!/usr/bin/env bash
# SessionStart hook: keeps ~/.claude-personal's per-project memory folder
# symlinked to the canonical one under ~/.claude, so notes saved under
# either config dir are visible from both. Safe to run every session start.
set -euo pipefail

PERSONAL_ROOT="$HOME/.claude-personal/projects"
WORK_ROOT="$HOME/.claude/projects"

payload="$(cat)"
transcript_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"

if [ -z "$transcript_path" ]; then
  exit 0
fi

project_dir_name="$(basename "$(dirname "$transcript_path")")"

PERSONAL_MEM="$PERSONAL_ROOT/$project_dir_name/memory"
WORK_MEM="$WORK_ROOT/$project_dir_name/memory"

# Already synced.
if [ -L "$PERSONAL_MEM" ]; then
  target="$(readlink -f "$PERSONAL_MEM" 2>/dev/null || true)"
  if [ "$target" = "$(readlink -f "$WORK_MEM" 2>/dev/null || true)" ]; then
    exit 0
  fi
fi

mkdir -p "$WORK_ROOT/$project_dir_name"
mkdir -p "$PERSONAL_ROOT/$project_dir_name"

if [ ! -e "$WORK_MEM" ]; then
  mkdir -p "$WORK_MEM"
fi

if [ -d "$PERSONAL_MEM" ] && [ ! -L "$PERSONAL_MEM" ]; then
  # Merge personal-only files into the work memory dir without clobbering.
  # MEMORY.md is just an index, so a colliding personal copy is discarded.
  # Any other colliding filename is preserved under a disambiguated name
  # so no note is ever silently lost.
  shopt -s nullglob dotglob
  for f in "$PERSONAL_MEM"/*; do
    base="$(basename "$f")"
    dest="$WORK_MEM/$base"
    if [ -e "$dest" ]; then
      if [ "$base" = "MEMORY.md" ]; then
        rm -f "$f"
      else
        conflict_dest="$WORK_MEM/personal-conflict-$base"
        n=2
        while [ -e "$conflict_dest" ]; do
          conflict_dest="$WORK_MEM/personal-conflict-$n-$base"
          n=$((n + 1))
        done
        mv "$f" "$conflict_dest"
        echo "sync-memory: $base already existed in $WORK_MEM; personal copy preserved as $(basename "$conflict_dest")" >&2
      fi
      continue
    fi
    mv "$f" "$dest"
  done
  shopt -u nullglob dotglob
  rmdir "$PERSONAL_MEM"
fi

if [ ! -e "$PERSONAL_MEM" ]; then
  ln -s "$WORK_MEM" "$PERSONAL_MEM"
fi

exit 0
