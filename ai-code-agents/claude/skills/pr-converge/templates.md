# Goal templates

Placeholders in double braces are filled at run time: `{{REPO}}` (owner/repo), `{{PR}}` (number), `{{TASK}}` (one line of text), `{{CHECK}}` (a command, shown as text, never run by the script). Print one with `bin/goal-line` and paste it after `/goal`:

- `goal-line ship-pr <owner/repo> <pr>`
- `goal-line ops <owner/repo> "<task>"`
- `goal-line backlog <owner/repo> "<task>" "<check command>"`
- `goal-line overnight <owner/repo> "<task>"`

Only the text between the begin and end markers of a template is printed.

## Ship-PR goal

<!-- begin ship-pr -->
Get PR {{PR}} on {{REPO}} to "ready to merge": run the pr-converge skill's loop from step A to one of its end states. Done when the loop ends at the skill's ready end state (END in its step E). Do not merge or promote the PR. If anything is denied or needs the owner, print one line `DECISION: <exact command> | <why>` and stop. Keep every reply under 1,000 characters. Stop after 40 turns.
<!-- end ship-pr -->

## Ops investigation

<!-- begin ops -->
Investigate: {{TASK}} on {{REPO}}. Read only: no writes, no pushes, no PRs, no config changes. Report the cause, the evidence and the proposed fix. If a step needs a write or is denied, print one line `DECISION: <exact command> | <why>` and stop. Stop after 15 turns.
<!-- end ops -->

## Backlog sweep

<!-- begin backlog -->
Work the item on {{REPO}}: {{TASK}}. Done when `{{CHECK}}` exits 0 and a PR is opened (opened, not merged; do not promote it). Use a fresh worktree, the repo's own gates, and the pr-converge skill for review. If anything is denied or needs the owner, print one line `DECISION: <exact command> | <why>` and stop. Keep every reply under 1,000 characters. Stop after 40 turns.
<!-- end backlog -->

## Overnight

One `claude --bg --permission-mode auto` session per independent item, each launched by the owner himself every time; nothing here launches one. An idle background session stops after about an hour. The prompt for each session is the text between the markers:

<!-- begin overnight -->
Precondition: the owner launched this session himself. Item: {{TASK}} on {{REPO}}. Rules: never force push. Never push to a default branch. Never merge, never promote a draft, never deploy, never run migrations, never read or write production, never write to shared databases. The only outward actions allowed are pushing its own branch, opening a draft pull request and posting the review (the pull request stays a draft PR). Work: do the item in a fresh worktree on its own branch, push that branch and open a draft pull request through the repo's own gates. Then run the pr-converge skill's loop from step A to one of its end states without asking questions, writing the `DECISION: <exact command> | <why>` line wherever the skill says stop. The end states are the pr-converge skill's end states: ready, or that DECISION line. If a push or any other action is denied, print `DECISION: <exact command> | <why>` and stop: never retry a denied action, no retry and no other route. The final reply is a table under 1,000 characters (item, state, PR link or DECISION line). Stop after 40 turns.
<!-- end overnight -->
