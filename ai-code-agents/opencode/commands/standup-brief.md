---
description: Check a teammate's last Slack DM, cross-reference it against this repo's open PRs/issues, and turn the result into a Brain story (via brain-story-split) linked to those issues.
---

# Standup brief: $ARGUMENTS

Default the target person to **Derek Brenner** if `$ARGUMENTS` doesn't name someone else. Default the scope to whatever repo the current working directory is in.

## Steps

1. **Read the DM.** Use the Slack MCP (`slack` in `global.opencode.json`) to find the person (user search), then read the DM channel with their user ID as the channel to pull their most recent messages. Identify what they're asking for or reacting to.

2. **Draft a reply** to their last message if it calls for one — short, matching their tone, no filler.

3. **Gather repo state.** Run `git status --short --branch`, `gh pr list --state open`, and `gh issue list --state open` in the current repo to see what's in flight.

4. **Cross-reference.** Identify which open PRs/issues are actually tied to the DM's topic (e.g. a client-feedback thread, a feature the person asked about). If more than 2-3 items need deep detail (full PR body, review status, linked issue), delegate to a `git-runner` subagent to fetch `gh pr view --json title,body,mergeable,statusCheckRollup,reviews` and `gh issue view` for each, and summarize — don't dump raw JSON into the main conversation.

5. **Turn it into a Brain story.** Don't hand-draft a task block here — invoke the
   `brain-story-split` skill and hand it what steps 1-4 gathered:

   - What the DM is actually asking for / reacting to — this becomes the story's
     title + plain-language description (understandable with no extra context).
   - The cross-referenced issues from step 4. These already exist, so skip
     `brain-story-split`'s step 3 ("create issues") entirely and go straight to
     its step 4 — link each one to the story via `task_external_links`. Only let
     it fall through to step 3 if the DM surfaces work that has no issue yet.
   - Derek as the reader the linked issues / Projects board need to be legible
     to — that's carried by the issues themselves, not restated in the story.
   - Let `brain-story-split` run its own new-story-vs-existing-story judgment
     call (its step 1) — if that's ambiguous, it will ask; don't pre-decide it
     here.
   - Let it drive the actual writes (task row, links, standup entry) — it
     confirms before anything live-writes.

Keep the final output to: the Slack reply draft, then whatever `brain-story-split`
reports back (story `task_id`/title, issues linked, which standup entry it landed
in). No manual task-block template, no per-PR breakdown unless asked.
