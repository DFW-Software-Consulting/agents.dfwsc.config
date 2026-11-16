# Git workflow skills

The old 503-line `git-workflow` skill is split into five single-purpose skills under `ai-code-agents/claude/skills/`. The `git-workflow` agent (`agents/git-workflow.md`) is a thin router; `/git` delegates to it unchanged. `skills/git-workflow/SKILL.md` is a stub that names the five so old references resolve.

All five return the same envelope: `{"skill","status": ok|blocked|needs_input,"branch","head","blocked_by":[],"result":{...},"next":[...]}`.

## Skills
| Skill | One job | Inputs | `result` | `next` |
|---|---|---|---|---|
| git-commit | commit approved groups | worktree, scope hint, `approved` | `proposed` (needs_input) or `committed`; `unstaged`, `skipped` (secret-looking files), `left_staged`; `log_tail`, `proposed_subject` on block | git-verify |
| git-verify | run checks, write stamp | worktree, `build` | `head`, `stamp`, `status`, `results`, `failed` on block | git-push, or git-pr when already pushed |
| git-push | publish the branch | worktree, branch, `head`, remote | `pushed_sha`, `remote`, `upstream`, `new_branch` | git-pr |
| git-pr | open a PR from a pushed branch | worktree, branch, base, issue number, gate links, verify `results` | `pr_url`, `title`, `base`, `template_used`, `loc`, `codeowners`; `body` and `command` if gh is missing | none |
| git-issue | create an issue | repo, description | `issue_url`, `number`, `template_used`, `open_questions`; `body` and `command` if gh is missing | none |

`blocked_by` holds short codes only: `detached-head`, `head-mismatch`, `no-remote`, `behind`, `diverged`, `push-failed`, `unpushed`, `gh-missing`, `dirty-tree`, `checks-failed`, `conflict-markers`, `hook-failed`, `message-rejected`, `error`. `next` is a hint; the router decides.

## Chains (set in the agent)
- commit: git-commit; verify: git-verify; push: git-commit, git-verify, git-push
- pr, changes not committed: git-commit, git-verify, git-push, git-pr
- pr, commits exist but are not pushed: git-verify, git-push, git-pr
- pr, branch already pushed: git-verify, git-pr
- issue: git-issue

An empty `committed` list from git-commit continues the chain. git-pr reads the `results` list of git-verify's result.

`git-commit` without `approved` returns `needs_input` with the proposed groups. The agent counts the proposal as approved only when the caller's brief explicitly pre-approves committing; otherwise the caller re-invokes it with the approved groups. A `blocked` or `needs_input` envelope ends the chain and is returned as it is.

## Helper
`local-hooks/git-facts.sh` prints repo facts as one JSON object (root, branch, default branch, upstream, ahead/behind, clean, linked worktree, PR and issue template paths, commitlint, husky, lint-staged, core.hooksPath, CODEOWNERS, changed lines against the default branch without lockfiles). Pushed state: `push_remote` (pushRemote setting, else `remote.pushDefault`, else the branch's remote, else origin), `push_ref` (`<remote>/<branch>` if it exists, else the upstream when that is not the default branch), `pushed`, `push_ahead`, `push_behind`. A branch made from `origin/main` tracks the default branch and reads as not pushed until its own remote branch exists. Read-only; sets PYTHONDONTWRITEBYTECODE; `--dir <path>`; a non-repo exits 2 with a JSON error. Suite: `run-git-facts-tests.sh`. Skills call it through the live path `~/.claude/local-hooks/git-facts.sh`.

## Rules and where they are enforced
| Rule | Enforced by |
|---|---|
| No hook bypass, no force push, no push to the default branch | git-guard.sh |
| No commit in a primary checkout | worktree-gate.sh |
| No coding-agent credit in commit or `gh pr` text | `hooks/no-agent-mention.py` |
| No private hostnames, addresses or emails in text on public repos | public-repo-text-gate.sh |
| Checks pass for the current commit before push or PR create | checks-gate.sh reads the stamp git-verify writes (warn or deny by its config) |
| Staged secret files, conflict markers, commit subject format | not enforced yet (skills only stage approved files) |
| PR size cap, PR body sections, branch pushed before PR | skill only: git-pr warns on size and checks `ahead` |

Repository hooks (husky, lint-staged, commitlint) run once, inside `git commit` and `git push`; no skill runs them by hand. No skill edits source files.

## Templates
- `skills/git-pr/templates/pr-body.md`: used when the repo has no PR template. No AI usage section.
- `skills/git-issue/templates/issue-body.md`: used when the repo has no `.md` issue template (yml issue forms cannot be filled with `--body`). A missing acceptance-criteria section gets a marked TBD line and an `open_questions` entry; the skill does not stop to ask.

## Template rules
Both body skills keep template headings in order, except a section the template marks conditional ("only if ...") that does not apply, which is removed. No angle-bracket placeholders or HTML comments remain; a missing value becomes a `TBD:` line with a reason. Unknown issue size leaves the boxes unchecked and becomes an open question. With several issue templates the skill matches the request type to a template name or front matter, else uses the bundled one.

## Decisions
- `gh` is needed for git-pr and git-issue only. Without it they return `blocked` (`gh-missing`) with the filled body and the command to run by hand.
- The agent gets the skills through the `skills:` list in its frontmatter (the five names). Their full content is injected into its context at start. It has no Skill tool and none is needed. A name that matches no skill is skipped silently, and a skill with `disable-model-invocation: true` cannot be preloaded. `local-hooks/tests/run-agent-skills-tests.sh` guards this: it fails if a listed name has no `skills/<name>/SKILL.md` with that `name`.
- The sibling tool ports (codex, opencode, gemini, cline, hermes) still carry the old single skill.
