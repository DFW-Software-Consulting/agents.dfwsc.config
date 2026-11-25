---
name: pr-converge
description: Use to drive one open PR toward "ready to merge" in bounded rounds of review, fix, push and wait for checks, with the repo's own pr-review verdict as proof. Use when the user says "converge this PR", "get this PR ready to merge", "review and fix PR 12 until it's green", or "run the PR loop". Never merges.
argument-hint: "<PR_NUMBER> <OWNER/REPO>"
---

# PR Converge

Take one PR from "open" to "reviewed at the current head, checks green" in at most 3 rounds. It stops there. This skill never merges, never promotes a draft, and never force pushes.

## Loop (at most 3 rounds)

Each round starts with a review. Rounds 1 and 2 may fix, push, wait and continue. Round 3 reviews only: if it is not ready, the run prints a DECISION line and stops, without fixing or pushing. So the last pushed head is always a reviewed head or is named in the DECISION line.

1. **Review.** Run the `pr-review` skill on the PR (`<PR_NUMBER> <OWNER/REPO>`). Read its `Verdict:` line and its `<!-- reviewed-head: <40-hex sha> -->` marker.
2. **Check the marker.** Read the PR's current head from GitHub (`gh pr view <pr> -R <owner/repo> --json headRefOid`). A review whose marker is missing or differs from that head counts as "not reviewed at this head": review again, never assume.
3. **Ready means** the verdict is exactly `✅ Ready to merge` (the first of the three verdict choices in `pr-review/SKILL.md`), the marker equals the head, and checks are green. Then write the report and stop. Mixed cases: verdict ready but checks still pending means wait (step 6); verdict ready but a check failed means the failing check is this round's must-fix item (in round 3, a DECISION line).
4. **Fix (rounds 1 and 2 only).** Dispatch one fix agent for the MUST-FIX and SHOULD-FIX items (not NITs). Its brief names the PR, the worktree, the items verbatim, the files, a `model`, and a "Done when" section (each item fixed, the relevant checks pass, nothing else changed). It does not push.
5. **Push.** Through the `git-verify` skill, then the `git-push` skill. Both stay as they are: checks first, then push, no `--force`. After every push, re-read `headRefOid` from GitHub (`gh pr view <pr> -R <owner/repo> --json headRefOid`) and use that value for the waiter's `--sha` and for comparing the marker. Never take the head from the local checkout.
6. **Wait for checks.** If `pr-wait` is on PATH, run `pr-wait <owner/repo> <pr> --sha <head>` in the background. Otherwise run a single `gh pr checks <pr> -R <owner/repo> --watch`. Never a sleep loop.
7. Next round starts with a re-review of the new head.

## Stops

Anything denied by a hook or gate, or anything that needs the owner (a failing check the fix agent cannot explain, a conflict, a missing permission, a design call, round 3 not ready), becomes exactly one line and the run stops:

`DECISION: <exact command> | <why>`

Do not retry a denied action, work around a gate, or try a second route.

## Never

- Never merges (no `gh pr merge`, no auto-merge, no merge button).
- Never promotes a draft to ready for review.
- Never force pushes, never bypasses a hook, never edits the default branch.

## Report (one screen)

- Rounds used (1 to 3)
- Final Verdict line, quoted
- Head sha, and whether the marker matches it
- Check summary (passed, failed, pending counts)
- Closing line: if a `pr-land` command is on PATH, the report may end with the line `! pr-land arm <owner/repo> <pr> --sha <head>`, plus one sentence: `pr-land` only watches the pull request and sends a notice when it is ready or why it is not, it never merges, and merging stays a command the owner runs himself. If `pr-land` is not on PATH, end with the plain "ready to merge" report. If the run stopped, the DECISION line instead.

## Overlap

Built-in `/ship` and `/steward` also watch a PR in-session and fix what they find. This skill adds the repo's own review verdict as proof, the reviewed-head marker, the round cap and the DECISION stop. If those do not matter for a given PR, the built-ins are fine.

Goal text for `/goal` and overnight runs lives in `templates.md`; print it with `bin/goal-line <template> <owner/repo> <pr>`.
