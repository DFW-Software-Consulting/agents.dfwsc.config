# Git workflow skills

The old 503-line `git-workflow` skill is split into five single-purpose skills under `ai-code-agents/claude/skills/`. The `git-workflow` agent (`agents/git-workflow.md`) is a thin router; `/git` delegates to it unchanged. `skills/git-workflow/SKILL.md` is a stub that names the five so old references resolve.

All five return the same envelope: `{"skill","status": ok|blocked|needs_input,"branch","head","blocked_by":[],"result":{...},"next":[...]}`.

## Skills
| Skill | One job | Inputs | `result` | `next` |
|---|---|---|---|---|
| git-commit | commit approved groups | worktree, scope hint, `approved` | `proposed` (needs_input) or `committed`; `unstaged`; `log_tail` on block | git-verify |
| git-verify | run checks, write stamp | worktree, `build` | `head`, `stamp`, `status`, `results` | git-push |
| git-push | publish the branch | worktree, branch, `head`, remote | `pushed_sha`, `remote`, `upstream`, `new_branch` | git-pr |
| git-pr | open a PR from a pushed branch | worktree, branch, base, issue number | `pr_url`, `title`, `base`, `template_used`, `loc`, `codeowners`; `body` and `command` if gh is missing | none |
| git-issue | create an issue | repo, description | `issue_url`, `number`, `template_used`, `open_questions`; `body` and `command` if gh is missing | none |

Blocked reasons are names in `blocked_by` (for example `detached-head`, `head-mismatch`, `diverged`, `unpushed`, `gh-missing`, `dirty-tree`, or the failing hook or command).

## Chains (set in the agent)
- commit: git-commit
- push: git-commit, git-verify, git-push
- pr, changes not committed: git-commit, git-verify, git-push, git-pr
- pr, branch already pushed: git-verify, git-pr
- issue: git-issue

`git-commit` without `approved` returns `needs_input` with the proposed groups; the caller re-invokes the agent with the approved ones. A `blocked` or `needs_input` envelope ends the chain and is returned as it is.

## Helper
`local-hooks/git-facts.sh` prints repo facts as one JSON object (root, branch, default branch, upstream, ahead/behind, clean, linked worktree, PR and issue template paths, commitlint, husky, lint-staged, core.hooksPath, CODEOWNERS, changed lines against the default branch without lockfiles). Read-only; `--dir <path>`; a non-repo exits 2 with a JSON error. Suite: `run-git-facts-tests.sh`. Skills call it through the live path `~/.claude/local-hooks/git-facts.sh`.

## Rules and where they are enforced
| Rule | Enforced by |
|---|---|
| No hook bypass, no force push, no push to the default branch | git-guard.sh |
| No commit in a primary checkout | worktree-gate.sh |
| No coding-agent credit in commit or `gh pr` text | `hooks/no-agent-mention.py` |
| No private hostnames, addresses or emails in text on public repos | public-repo-text-gate.sh |
| Checks pass for the current commit | not enforced; git-verify writes a stamp, no gate reads it yet |
| Staged secret files, conflict markers, commit subject format | not enforced yet (skills only stage approved files) |
| PR size cap, PR body sections, branch pushed before PR | skill only: git-pr warns on size and checks `ahead` |

Repository hooks (husky, lint-staged, commitlint) run once, inside `git commit` and `git push`; no skill runs them by hand. No skill edits source files.

## Templates
- `skills/git-pr/templates/pr-body.md`: used when the repo has no PR template. No AI usage section.
- `skills/git-issue/templates/issue-body.md`: used when the repo has no `.md` issue template (yml issue forms cannot be filled with `--body`). A missing acceptance-criteria section gets a marked TBD line and an `open_questions` entry; the skill does not stop to ask.

## Decisions
- `gh` is needed for git-pr and git-issue only. Without it they return `blocked` (`gh-missing`) with the filled body and the command to run by hand.
- Skills are named in the agent's prose; the agent has no Skill tool and no `skills:` frontmatter (same as before the split), so check that the skill text actually reaches it when you change this.
- The sibling tool ports (codex, opencode, gemini, cline, hermes) still carry the old single skill.
