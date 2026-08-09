---
allowed-tools: mcp__claude_ai_Slack__slack_search_users, mcp__claude_ai_Slack__slack_read_channel, Bash(git:*), Bash(gh:*), Task
description: Check a teammate's last Slack DM, cross-reference it against this repo's open PRs/issues, and draft one consolidated portal task.
---

# Standup brief: $ARGUMENTS

Default the target person to **Derek Brenner** if `$ARGUMENTS` doesn't name someone else. Default the scope to whatever repo the current working directory is in.

## Steps

1. **Read the DM.** Use `slack_search_users` to find the person, then `slack_read_channel` with their user ID as the channel to pull their most recent messages. Identify what they're asking for or reacting to.

2. **Draft a reply** to their last message if it calls for one — short, matching their tone, no filler.

3. **Gather repo state.** Run `git status --short --branch`, `gh pr list --state open`, and `gh issue list --state open` in the current repo to see what's in flight.

4. **Cross-reference.** Identify which open PRs/issues are actually tied to the DM's topic (e.g. a client-feedback thread, a feature the person asked about). If more than 2-3 items need deep detail (full PR body, review status, linked issue), delegate to a `git-workflow` subagent to fetch `gh pr view --json title,body,mergeable,statusCheckRollup,reviews` and `gh issue view` for each, and summarize — don't dump raw JSON into the main conversation.

5. **Write ONE consolidated task** (not one per PR) using this exact template, filling every field:

   ```
   Title:
   Owner: JC Ashley
   Priority: P_ · Product Development
   Estimated time (hours):
   Due date:
   Milestone:
   Status:
   Definition of done:
   Notes:
   ```

   Guidance for filling it in:
   - **Estimated time** = remaining work only (merge/deploy/verify), not time already spent building — assume the linked PRs are already code-complete unless stated otherwise.
   - **Definition of done** = a checklist of specific, verifiable end-states (PRs merged, migrations pushed to sandbox+prod, secrets set, a manual smoke-check performed) — never a vague "finish the feature."
   - **Due date** — leave as "(your call)" rather than guessing; it's JC's decision.
   - **Milestone** — check `gh issue list --json number,milestone` for the linked issues first; only suggest creating a new one if none exists and it'd meaningfully group the work.
   - **Notes** — call out anything that changed scope from the original issue, anything still blocked on a client/human decision, and any issue number this batch explicitly does *not* close (to avoid false-closing related work).

Keep the final output to: the Slack reply draft, then the one task block. No per-PR breakdowns unless asked.
