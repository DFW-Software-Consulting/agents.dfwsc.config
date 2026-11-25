# Goal templates

Placeholders in double braces are filled at run time: `{{REPO}}` (owner/repo), `{{PR}}` (number), `{{TASK}}` (one line of text), `{{CHECK}}` (a command, shown as text, never run by the script). Print one with `bin/goal-line` and paste it after `/goal`:

- `goal-line ship-pr <owner/repo> <pr>`
- `goal-line ops <owner/repo> "<task>"`
- `goal-line backlog <owner/repo> "<task>" "<check command>"`
- `goal-line overnight <owner/repo> "<task>"`

Only the text between the begin and end markers of a template is printed.

## Ship-PR goal

<!-- begin ship-pr -->
Get PR {{PR}} on {{REPO}} to "ready to merge": run the pr-converge skill on it. Done when the latest pr-review verdict is "Ready to merge", its reviewed-head marker equals the PR head, and checks are green. Do not merge or promote the PR. If anything is denied or needs the owner, print one line `DECISION: <exact command> | <why>` and stop. Keep every reply under 1,000 characters. Stop after 40 turns.
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
Precondition: the owner launched this session himself. Item: {{TASK}} on {{REPO}}. End in one of two states: "PR open, checks green, review posted", or a line `DECISION: <exact command> | <why>`. Rules: never force push. Never push to a default branch. Never merge, never promote a draft, never deploy, never run migrations, never read or write production, never write to shared databases. The only outward actions allowed are pushing its own branch, opening a draft pull request and posting the review (the pull request stays a draft PR). Flow: (a) before the first push, its checks pass locally; a local-mode review before the first push is optional, posts nothing and does not count as a round. (b) Push. (c) After every push, including the first, run one PR-mode review of the pushed head: it posts the review comment the first time and amends that same comment afterwards, and each PR-mode review is one round. (d) The end state is a review posted whose reviewed-head marker equals the current head. If a push or any other action is denied, print `DECISION: <exact command> | <why>` and stop: never retry a denied action, no retry and no other route. The final reply is a table under 1,000 characters (item, state, PR link or DECISION line). Stop after 40 turns.
<!-- end overnight -->
