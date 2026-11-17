---
name: brain-story-split
description: Use when new work needs to become a Brain task (the "story") and/or GitHub issues (the technical breakdown) — deciding whether it's a new story or belongs under one already open, writing the brain.tasks row, linking the resulting GitHub issues back to it, and wording the daily standup entry for its actual reader. Run this before creating a Brain task or a batch of GitHub issues for new work.
---

# Brain Story / GitHub Issue Split

Answers two questions in order: (1) is this new work its own Brain story, or does
it belong under one already open, and (2) once that's settled, how does the
technical breakdown get written so Brain and GitHub each serve the reader they
actually have.

## The mental model

- **`brain.tasks` row = the story.** One commitment-sized piece of "what needs to
  be done," written in plain narrative — understandable with zero extra context.
  This is what the daily standup references (`brain.standups.primary_task_id` /
  `secondary_task_id`, `brain.standup_items.task_id`) and it's **CEO-facing**: the
  9:30am morning entry (priorities + time estimate) and the 5:30pm+ end-of-day
  entry (completed / not-completed / blockers), per the standup policy.
- **GitHub issues = the technical breakdown of that story** — however many it
  takes (often 5-6). Each one is linked back to the story via a
  `brain.task_external_links` row (`kind = 'github'`), not folded into the task
  itself. This is **Derek-facing**: he reads the issues and the org's GitHub
  Projects board (`brain.projects.github_project_number` — the board tied to this
  project).
- A story can carry many issues. An issue shouldn't float with no story above it,
  even a lightweight one — that's what makes the standup line meaningful instead
  of a raw PR/issue link dump.

## The judgment call: new story, or fold into an existing one?

- **Default:** if the new work is naturally inside the scope of an already-open
  story (`status` not `done`), add GitHub issues under that existing `task_id`.
  Don't spawn a new story for every ticket.
- **Override:** create a new, separate `brain.tasks` row whenever the point is
  *visibility to leadership* — JC wants this to read as its own line in the
  commitment/EOD update, distinct from an existing story, even though it
  technically overlaps that story's scope.
- This is JC's call, not something to decide silently. When it's ambiguous, ask
  rather than picking a side — folding it in quietly makes it invisible as
  separate work; splitting it out when it isn't warranted clutters the commitment
  list.

## Never edit someone else's records

Same rule as [[brain-locate]] applies to everything this skill writes, not just
project lookups: before updating an **existing** `brain.tasks` row, check
`owner_person_id` and `created_by_person_id`. If it belongs to someone other than
the person this session is acting for, don't update, reassign, or "simplify" it —
surface it and let them decide.

## Steps

### 0. Resolve the project

If `project_id` / `organization_id` for this repo isn't already known this
session, run the `brain-locate` skill first. Everything below needs `project_id`.

### 1. Decide: new story, or existing?

Apply the judgment call above. Check for an open candidate first:

```sql
select id, title, status, owner_person_id, created_by_person_id
from brain.tasks
where project_id = '<project_id>'
  and status != 'done'
order by updated_at desc;
```

If nothing fits, or JC wants this visible as its own line — go to 2a. If an open
task already covers this — confirm ownership, then skip to 3 using its `id`.

### 2a. New story: insert the task

```sql
insert into brain.tasks (
  project_id, title, description, owner_person_id, priority,
  estimate_hours, definition_of_done, due_date, status,
  github_push_state, created_by_person_id
) values (
  '<project_id>',
  '<title — the story, one line>',
  '<plain-language narrative: what and why, understandable with no extra context>',
  '1b9f60ac-46ba-4b04-85a1-f70c204c2fb1',
  '<p0|p1|p2>',
  <total estimated hours or null>,
  '<definition of done — a verifiable checklist, not a vague goal>',
  <due_date or null>,
  'not_started',
  'skipped',
  '1b9f60ac-46ba-4b04-85a1-f70c204c2fb1'
)
returning id;
```

**Set `github_push_state = 'skipped'` deliberately.** There is existing
automation that watches new `brain.tasks` rows and auto-pushes each one to
GitHub as its own single issue (the enum cycles `pending` → `linked`/`failed`,
and a matching `task_external_links` row appears — every current example in the
table is one task linked to exactly one issue). That 1-task-to-1-issue default
is wrong for a story that's about to fan out into several issues — `skipped`
stops it from creating a throwaway issue for the story row itself. This was
inferred from the schema and column names, not from reading the automation's
actual trigger logic — mention it to JC in the moment rather than assuming it's
still exactly this, and re-check `github_push_state` if a link shows up that you
didn't create.

### 2b. Existing story: confirm ownership

Only proceed past step 1 with an existing task if `owner_person_id` and
`created_by_person_id` belong to the person this session is acting for. If not,
stop and surface it — do not attach new issues to someone else's story without
asking.

### 3. Break the story into GitHub issues

Don't reimplement issue-writing here. Hand off to whichever existing skill fits
the batch:

- 1-5 items → `plan-quick`
- 10+ item brain dump → `plan-and-issue`
- Turning an existing plan/spec/PRD into tracer-bullet issues → `to-issues`

These already file into the right repo and Projects board per
`.Codex/project.json`. This skill only owns the Brain-side wiring around them.

### 4. Link each issue back to the story

One row per issue — this is what makes "N issues under one story" queryable
later, in the same shape already used elsewhere in the Brain:

```sql
insert into brain.task_external_links (task_id, kind, external_id, url, label)
values (
  '<story_task_id>',
  'github',
  '<owner/repo>#<n>',
  'https://github.com/<owner/repo>/issues/<n>',
  'GitHub issue #<n>'
);
```

Repeat per issue created in step 3.

### 5. Write the story into the standup — in the right voice for the right reader

**Format every standup text field as Markdown** (JC's rule, 2026-08-24 — the portal
renders it). That means `primary_deliverable`, `completed`, `not_completed`, `reason`,
`first_task_tomorrow`, `blockers`, and `standup_items.body`: use `**Bold Project
Name**` section headers when the entry spans more than one project, and `- ` bullet
lists for the items under each — no plain-prose paragraph dumps. Single-sentence
fields still get a leading `- `. Keep the plain-language, CEO-facing voice; Markdown
changes the shape, not the register.

`morning` and `end_of_day` are **separate rows**, not one row that transitions —
`brain.standups` has a `unique (person_id, entry_date, kind)` constraint, plus a
check constraint requiring `primary_deliverable` on a `morning` row and
`completed` on an `end_of_day` row. Both are self-contained here; this
supersedes the older memory note ([[brain-standup-write-path]]) that pointed at
the mechanics without inlining them — that memory can be pruned/shortened to
just point back at this skill.

**Before drafting anything**, pull yesterday's end-of-day row so today's morning
entry doesn't drop a carryover:

```sql
select entry_date, first_task_tomorrow, not_completed, blockers
from brain.standups
where person_id = '1b9f60ac-46ba-4b04-85a1-f70c204c2fb1'
  and kind = 'end_of_day'
order by entry_date desc
limit 1;
```

**Morning (by 9:30am).** Check today's row doesn't already exist before
inserting:

```sql
select id from brain.standups
where person_id = '1b9f60ac-46ba-4b04-85a1-f70c204c2fb1'
  and entry_date = current_date and kind = 'morning';
```

If none, insert one — `primary_deliverable` is the plain narrative a CEO reads
with zero other context, not implementation detail:

```sql
insert into brain.standups (
  person_id, entry_date, kind,
  primary_task_id, primary_deliverable, estimated_hours,
  secondary_task_id, secondary_text, posted_at
) values (
  '1b9f60ac-46ba-4b04-85a1-f70c204c2fb1', current_date, 'morning',
  '<story_task_id>', '<one-line plain-language deliverable>', <hours>,
  <secondary_task_id or null>, <secondary_text or null>, now()
)
returning id;

insert into brain.standup_items (standup_id, position, task_id, body, estimated_hours)
values
  ('<standup_id>', 1, '<story_task_id>', '<mirrors primary_deliverable>', <hours>),
  ('<standup_id>', 2, <secondary_task_id or null>, '<secondary_text>', <hours2>);
```

Drop the position-2 row if there's no secondary item today. `source` defaults
to `'manual'` — no need to set it.

**End of day (5:30pm+).** A *new* row, same `entry_date`, `kind='end_of_day'` —
still story-level plain language ("shipped 2 of 6 issues on X, blocked on a
client decision," not a list of PR links):

```sql
insert into brain.standups (
  person_id, entry_date, kind, primary_task_id,
  completed, not_completed, reason, first_task_tomorrow, blockers, posted_at
) values (
  '1b9f60ac-46ba-4b04-85a1-f70c204c2fb1', current_date, 'end_of_day', '<story_task_id>',
  '<what shipped, plain language>', '<what did not, or null>', '<why, if anything slipped>',
  '<carryover for tomorrow''s morning entry, or null>', '<blockers, or null>', now()
);
```

Then tick off whichever of today's `standup_items` actually finished — this
updates the *morning* rows in place, it doesn't create new ones:

```sql
update brain.standup_items
set completed_at = now(), outcome = '<shipped|carried|dropped>'
where standup_id = '<today''s morning standup id>' and position = <1 or 2>;
```

The GitHub issues and Projects board carry the technical detail (acceptance
criteria, code pointers, review status, per-issue priority if it differs from
the story). That detail does not need to be repeated in the Brain story or the
standup text — keep the two surfaces distinct: Brain narrates what/why for
leadership, GitHub tracks how for the technical reviewer.

### 6. Report

State plainly, once done:

- The story's `task_id` (new or reused) and title
- Which issues got linked (`owner/repo#n` list)
- Which standup entry it landed in (morning/EOD, date)
