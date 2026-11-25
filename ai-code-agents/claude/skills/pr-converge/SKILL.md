---
name: pr-converge
description: Use to drive one open PR toward "ready to merge" in bounded rounds of review, fix, push and wait for checks, with the repo's own pr-review verdict as proof. Use when the user says "converge this PR", "get this PR ready to merge", "review and fix PR 12 until it's green", or "run the PR loop". Never merges.
argument-hint: "<PR_NUMBER> <OWNER/REPO>"
---

# PR Converge

Take one PR from "open" to "reviewed at the current head, checks green" in at most 3 rounds. It stops there. This skill never merges, never promotes a draft, and never force pushes.

## Loop (at most 3 rounds)

This is the only description of the loop; templates and docs point here. A round is one PR-mode review. Every review run counts as a round, whatever triggered it (the first review, a review of a pushed head, or a review after a marker mismatch). There is no extra review. Start at step A; each step names the step that follows it, and the run ends only at END (ready) or at a DECISION line (see Stops).

State: R is the number of PR-mode reviews this run has started; it begins at 0. H is the PR's head commit as GitHub reports it (`gh pr view <pr> -R <owner/repo> --json headRefOid`), re-read whenever a step below says so; never take it from the local checkout.

A review starts only in step B. A fix is made only in step D. Only step E waits.

**Step A: prepare.** If the run has no local commits that are not yet on the PR branch, go to step B. Otherwise run the local checks through the `git-verify` skill; if they do not pass, stop with a DECISION line. A local-mode review before this push is optional, posts nothing and does not count as a round (R is unchanged). When the checks pass, push through the `git-push` skill (no `--force`), then go to step B.

**Step B: review.** If R is 3, stop at the cap with a DECISION line: name H and the marker seen (or that none was found). Otherwise re-read H from GitHub, run one PR-mode review of H with the `pr-review` skill (`<PR_NUMBER> <OWNER/REPO>`), and add 1 to R. The first review posts the review comment; every later one amends that same comment. Then go to step C.

**Step C: read the result.** Re-read H from GitHub. Read the review's `<!-- reviewed-head: <40-hex sha> -->` marker exactly as the "Reviewed-head marker" section of `pr-review/SKILL.md` defines it (only the comment its amend rule selects, only its last line). If the marker is missing, malformed or not equal to H, the result counts as not reviewed at this head: go to step B. Otherwise read the `Verdict:` line: if it is exactly `✅ Ready to merge` (the first of the three verdict choices in `pr-review/SKILL.md`) and no MUST-FIX or SHOULD-FIX item is open, go to step E; in every other case the result is not ready: go to step D.

**Step D: fix.** Entered from step C when the result is not ready, or from step E when a check failed (the failing check is the item to fix). If R is 3, stop with a DECISION line without fixing or pushing (round 3 reviews only), because a fix made now could not be reviewed. Otherwise dispatch one fix agent for the MUST-FIX and SHOULD-FIX items, or the failing check (not CONSIDER items). Its brief names the PR, the worktree, the items verbatim, the files, a `model`, and a "Done when" section (each item fixed, the relevant checks pass, nothing else changed). It does not push. Then run the local checks through `git-verify` until they pass (a failure the fix agent cannot explain is a DECISION stop), push through `git-push` (no `--force`), and go to step B.

**Step E: wait for checks.** Entered only from step C with a ready result for H. If `pr-wait` is on PATH, run `pr-wait <owner/repo> <pr> --sha <H> --timeout 60m` once, in the background; never a sleep loop. Its exit code decides the next step:
- Exit 0 (green) or exit 5 (no checks): END, ready. A review is posted whose marker equals H, checks are green or there are none, and a person merges. Write the report.
- Exit 1 (failed): go to step D (its cap check comes first).
- Exit 2 (timeout), 3 (head changed), 4 (closed or merged) or 10 (usage or gh error): stop with a DECISION line naming the outcome and H (on timeout, also the checks still pending); no second wait, and do not loop.

If `pr-wait` is not installed, do not substitute another command: stop with a DECISION line whose command is the wait above and whose reason says the review is posted for H and checks were not awaited.

## Stops

Anything denied by a hook or gate, or anything that needs the owner (a failing check the fix agent cannot explain, a conflict, a missing permission, a design call, round 3 not ready), becomes exactly one line and the run stops:

`DECISION: <exact command> | <why>`

Do not retry a denied action, work around a gate, or try a second route.

## Never

- Never merges (no `gh pr merge`, no auto-merge, no merge button).
- Never promotes a draft to ready for review.
- Never force pushes, never bypasses a hook, never edits the default branch.
- Never starts a review outside step B, never makes a fix outside step D, never waits outside step E.

## Report (one screen)

- Rounds used (R, 0 to 3)
- Final Verdict line, quoted
- Head sha, and whether the marker matches it
- Check summary (passed, failed, pending counts)
- Closing line: if a `pr-land` command is on PATH, the report may end with the line `! pr-land arm <owner/repo> <pr> --sha <head>`, plus one sentence: `pr-land` only watches the pull request and sends a notice when it is ready or why it is not, it never merges, and merging stays a command the owner runs himself. If `pr-land` is not on PATH, end with the plain "ready to merge" report. If the run stopped, the DECISION line instead.

## Overlap

Built-in `/ship` and `/steward` also watch a PR in-session and fix what they find. This skill adds the repo's own review verdict as proof, the reviewed-head marker, the round cap and the DECISION stop. If those do not matter for a given PR, the built-ins are fine.

Goal text for `/goal` and overnight runs lives in `templates.md`; print it with `bin/goal-line <template> <owner/repo> <pr>`.
