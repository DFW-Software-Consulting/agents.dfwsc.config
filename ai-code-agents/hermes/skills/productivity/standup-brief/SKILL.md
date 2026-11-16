---
name: standup-brief
description: Check a teammate's last Slack DM, cross-reference this repo's open PRs/issues, and turn it into a Brain story via brain-story-split. Needs Slack + Supabase MCP servers.
---

> **Arguments:** the text typed after `/standup-brief` reaches you as the user instruction alongside the skill invocation. Wherever this skill says "the request" (called `$ARGUMENTS` in the original Claude command), it means that text.

> **Prerequisites (not available in the current Hermes config):** this command needs (1) a **Slack MCP server** with user-search and channel-read tools (Claude used `mcp__claude_ai_Slack__slack_search_users` and `mcp__claude_ai_Slack__slack_read_channel`) and (2) a **Supabase MCP server** with an `execute_sql` tool for the Brain database (Claude used `mcp__claude_ai_Supabase__execute_sql`; the `brain-story-split` skill does the writes). Hermes names MCP tools `mcp__<server>__<tool>`, so they will appear under whatever server names you configure. If either server is missing, say so plainly, do what is possible (steps 3-4 only need `git`/`gh`), and do not invent data. Also needs the `gh` CLI authenticated and the `brain-story-split` skill loaded.

# Standup brief: the request

Default the target person to **Derek Brenner** if `the request` doesn't name someone else. Default the scope to whatever repo the current working directory is in.

## Steps

1. **Read the DM.** Use the Slack MCP server's user-search tool (Claude name: `slack_search_users`) to find the person, then its read-channel tool (Claude name: `slack_read_channel`) with their user ID as the channel to pull their most recent messages. Identify what they're asking for or reacting to.

2. **Draft a reply** to their last message if it calls for one — short, matching their tone, no filler.

3. **Gather repo state.** Run `git status --short --branch`, `gh pr list --state open`, and `gh issue list --state open` in the current repo to see what's in flight.

4. **Cross-reference.** Identify which open PRs/issues are actually tied to the DM's topic (e.g. a client-feedback thread, a feature the person asked about). If more than 2-3 items need deep detail (full PR body, review status, linked issue), delegate to a subagent (`delegate_task`; tell it to use `gh` via the terminal tool) to fetch `gh pr view --json title,body,mergeable,statusCheckRollup,reviews` and `gh issue view` for each, and summarize — don't dump raw JSON into the main conversation.

5. **Turn it into a Brain story.** Don't hand-draft a task block here — load and follow the
   `brain-story-split` skill (`skill_view`) and hand it what steps 1-4 gathered:

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
