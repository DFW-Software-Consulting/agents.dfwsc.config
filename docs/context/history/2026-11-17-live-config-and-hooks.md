# Live configuration from main, headless cap, commit-message check, schema hint (pull requests 36 to 39)
Date: 2026-11-17
Scope: what pull requests 36 to 39 added or changed.
Findings:
- #36 Lands the long-running response-length-cap branch on main, identifiers scrubbed (squash). Brings in new and updated skills, agents, commands and tool configs. The OpenCode config reads two values through environment-variable substitution and the settings snapshot uses placeholders. Afterwards skills, agents and commands in both Claude configuration directories were linked to the main worktree, like hooks.
- #37 The reply cap skips headless runs whose entrypoint is exactly `sdk-cli` or `sdk-ts` (environment, else transcript with one allowed value throughout); unknown, missing and mixed stay capped. Reason: scheduled headless jobs had their output replaced by a short acknowledgement.
- #38 The commit-message hook accepts a clean heredoc message on standard input for a plain commit preceded only by simple commands, reads a file name with glued punctuation, and the heredoc-written file case; it scans heredoc bodies and trailer values. Anything that can redefine a command keeps the old behaviour. Another program's `-F` on a line holding both words is still denied.
- #39 Adds brain-schema-hint, a context-only hook for the Brain database tools that reads corrections from a private card outside the repo. It never blocks and is registered for two events because it is unconfirmed which one a failed call raises.
Lessons:
- Never change which lines the commit-message hook judges and never add skip lists; change only how the message source is resolved and prove it with the differential test against the pinned baseline.
- Check `readlink -f` for the checkout a live link serves.
- Before pushing a long-lived branch, check the ahead count and scan the unpushed diff for identifiers; do not trust an "already pushed" report.
- A hook that replies to every Stop event breaks headless jobs that return their result as the final message.
- Real identifiers and the private schema card are never committed.
