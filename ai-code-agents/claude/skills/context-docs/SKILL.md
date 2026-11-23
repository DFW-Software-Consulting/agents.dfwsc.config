---
name: context-docs
description: Use when asked to set up, add to, or update a repo's docs/context/ documentation (INDEX.md, topic docs, history entries, errors.md). Maintains the context-docs convention that session and subagent hooks inject.
---

# Context Docs

Maintain a repo's context docs: short, durable notes that agents read before working and update after.

## Convention

- A repo opts in by having `docs/context/INDEX.md`. Without it the repo is not opted in and nothing is injected.
- `INDEX.md` is the table of contents, one line per doc:
  `- [file.md](file.md) : read when <trigger>`
- Context docs live at `docs/context/<area>-<topic>.md` (for example `auth-sessions.md`).
- Past audits and lessons go in `docs/context/history/YYYY-MM-DD-<slug>.md`.
- `docs/context/errors.md` is a running error log. Check it before proposing a fix, including each entry's "Tried and failed" notes, so a known dead end is not retried.

## Scaffold a repo

Only when the user asks for that specific repo. Do not scaffold on your own.

1. Work in a worktree, never the primary checkout.
2. Create `docs/context/INDEX.md` with a one-line header and no entries yet.
3. Create `docs/context/errors.md` with a title and the entry format below (cause, fix, optional tried-and-failed, date).
4. Add the first topic docs only if the user names them.

## Add or update a doc

1. Write or edit `docs/context/<area>-<topic>.md`. Keep it factual and short; link to code paths instead of copying code.
2. Add or fix its line in `INDEX.md`. The trigger must say when an agent should read it ("read when changing the billing webhook"), not what the file contains.
3. Remove INDEX lines for docs that no longer exist. Keep INDEX.md under about 3,000 characters; the start hook truncates beyond that.
4. Do not record secrets, hostnames or credentials, especially in public repos.

## History entry

File `docs/context/history/YYYY-MM-DD-<slug>.md`:

```
# <title>
Date: YYYY-MM-DD
Scope: <what was audited or changed>
Findings: <bullets>
Lessons: <what to do differently>
```

History is not listed in INDEX.md unless it is still actively useful.

## Error log entry

Append newest first to `docs/context/errors.md`:

```
## <short error signature, the message text you would grep for>
- Cause: <root cause>
- Fix: <what resolved it>
- Tried and failed: <what was attempted that did not work, and why>
- Date: YYYY-MM-DD
```

`Tried and failed` is optional: leave it out when there were no failed attempts. When there were, record each one with the reason it failed, because readers check this field before proposing a fix and skip those approaches.

## Reporting

The hand-back gate looks for the `Context docs` label at the start of a line (optionally after a bullet, number or `>`, optionally bold), followed by `:` or a dash. Each Acceptance check line must also carry evidence (what you ran or inspected and the result); a bare `met` is sent back. End your report with `Context docs: updated <files>`, `Context docs: no change needed, <reason>`, or `Context docs: none in this repo`.
