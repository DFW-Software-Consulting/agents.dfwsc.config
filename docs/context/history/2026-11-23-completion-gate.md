# 2026-11-23: completion gate

## Why
Subagent hand-backs were gated (handback-gate.sh) but the main session's own final reply was not: a turn could end saying the work is done after code changed with no passing check record and no word about verification.

## What
`completion-gate.sh` (UserPromptSubmit baseline, Stop check). It blocks once, asking for a one-line statement, and never forces checks to run: an honest `Not verified:`, `Blocked:` or `In progress:` passes.

## Decisions
- Baseline is the worktree list with HEADs plus a timestamp, not a file snapshot, so the prompt step stays about one git call. Uncommitted work is found at Stop by comparing file times with the baseline time; commits by comparing HEADs.
- The owner's work happens in linked worktrees via subagents, so every worktree of the cwd's repository is scanned, not only the cwd.
- Reuses `_checks_stamp.py` records and the checks gate's documentation pattern. Repos without checks are exempt, as in the checks gate.
- The baseline is rewritten after each Stop, so a stop without a new prompt (a background task wake-up) only judges newer changes.
- Skips the scan when the turn's tool use shows no Edit, Write, NotebookEdit, Bash or Agent call; a missing transcript means scan.

## Registration
Not registered in the repo's settings.json (local hooks never are; see hooks-shipping.md step 6). After merge, add to each live settings file (the `~` form is an inference, not tested; use the absolute path your other entries use if `~` is not expanded):
- UserPromptSubmit: command `bash ~/.claude/local-hooks/completion-gate.sh`
- Stop: command `bash ~/.claude/local-hooks/completion-gate.sh`, timeout 15, next to the response-cap entry.

## Known limits
- Only the session's own repository (and its linked worktrees) is watched; a change in another repository is missed.
- Deleted files have no file time, so a turn that only deletes uncommitted files is missed.
- A reply that contains a statement line without having verified anything passes; the gate checks that a claim was made, not that it is true.
- Uncommitted code is never covered by a stamp (stamps are per commit), so such a turn needs a statement.
