---
name: brain-locate
description: Use when you need to know which Craft Digital Brain project/org record (in the live Supabase `brain` schema) corresponds to the client codebase you're currently sitting in. Resolves the current repo to a `brain.projects` row and reports its project_id/organization_id for any downstream Brain write (tasks, facts, decisions). Run this first, before writing anything into the Brain for a project you haven't confirmed yet.
---

# Brain Locate

Answers one question: "which row in `brain.projects` is *this* codebase?" — so any
Brain-writing work (tasks, facts, decisions) targets the right project without
guessing.

This is a stand-in for a proper MCP server lookup tool (e.g. `get_project_for_repo`)
that will replace this later. Until that exists, this skill does the resolution by
hand and — importantly — **writes the answer back into the database** so the lookup
gets easier over time instead of staying a one-off guess.

Brain project ref: `fieozyvfuhyhtuprjnwz` (Supabase). Query it via the
`mcp__claude_ai_Supabase__execute_sql` tool — it's a deferred tool; if it hasn't been
loaded this session, fetch it first with `ToolSearch("select:mcp__claude_ai_Supabase__execute_sql")`.

## Never edit someone else's records

The Brain is shared across the whole Craft Digital team, not private to whoever's
running this skill — real people (engineers, ops, leadership) already have tasks,
decisions, and other rows attributed to them in there. Before writing to any
**existing** row (task, decision, action_item, fact, etc.), check who it belongs to:

- Tasks / action items: `owner_person_id` (and `created_by_person_id`)
- Decisions: `decided_by`
- Anything else: whatever ownership/attribution column it has

If the owner is someone other than the person you're operating on behalf of this
session, **do not update, delete, reassign, or "simplify" that row** — surface it to
the user instead and let them decide. This holds even for cleanup/consolidation
passes; only touch rows the current user created or owns. New rows you create on
their behalf should be attributed to them, not left unowned or handed to someone
else without being asked.

## Arguments

Optional free-text hint (e.g. `/brain-locate "RTA Designs"`) — use it as an extra
search term if git-remote parsing comes up empty or ambiguous. No argument needed in
the common case; the skill figures it out from the repo itself.

## Steps

### 1. Gather local signal

- Run `git remote get-url origin` from the current repo root (walk up if cwd is a
  subdirectory). Parse `owner/repo` out of it — handle both
  `git@github.com:owner/repo.git` and `https://github.com/owner/repo` forms.
- If there's no remote (or the command fails), fall back to the repo/directory
  basename as the search term (e.g. `xl-configurator`).
- Note a human-readable name too if obvious (README title, `package.json` `name`
  field) — for display only, not for matching precision.

### 2. Try an exact match first

```sql
select p.id, p.name, p.slug, p.github_repo, p.organization_id, o.name as org_name
from brain.projects p
join brain.organizations o on o.id = p.organization_id
where p.github_repo = '<owner/repo>';
```

If this returns exactly one row, you're done — report it (step 6) and stop. No
write needed; the mapping was already correct.

### 3. Fuzzy fallback

If step 2 finds nothing, search more loosely:

```sql
select p.id, p.name, p.slug, p.github_repo, p.organization_id, o.name as org_name
from brain.projects p
join brain.organizations o on o.id = p.organization_id
where p.name ilike '%<term>%' or p.slug ilike '%<term>%' or p.github_repo ilike '%<term>%'
   or o.name ilike '%<term>%';
```

Try a couple of variants of `<term>` (the raw repo name, and a de-hyphenated /
de-prefixed version — e.g. `xl-configurator` -> also try `configurator`, `xl
trailers`). Present whatever candidates turn up to the user in plain chat — id,
name, org, current `github_repo` value (if any) — and ask them to confirm which
one it is, or say none match.

### 4. No match at all

If nothing plausible turns up (or the user says none of these), say so plainly:
this codebase has no matching Brain project yet. **Stop there.** Do not create a
new `brain.projects` row — onboarding a new project/client is a bigger decision
than this skill should make on its own; flag it back to the user instead.

### 5. Persist the mapping

Once the user confirms a project, and only if its `github_repo` is empty or
wrong: show the exact UPDATE you're about to run, then run it.

```sql
update brain.projects
set github_repo = '<owner/repo>'
where id = '<confirmed-project-id>';
```

This is a data fill on an existing nullable text column, not a schema change —
but it's still a live write, so confirm with the user first per usual practice
here.

### 6. Report

State clearly, for whatever called this skill to use next:

- `project_id`
- `organization_id`
- project name / org name (for a sanity-check readback)

That's the payload any downstream Brain write (a task insert, etc.) should key
off of.
