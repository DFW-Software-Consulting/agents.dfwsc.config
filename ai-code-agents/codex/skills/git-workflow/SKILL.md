---
name: git-workflow
description: Use when committing, pushing, creating PRs, or creating GitHub issues. Enforces pre-commit/pre-push checks, reads project .github/ templates, and creates issues/PRs via GitHub MCP tools (preferred) or gh CLI (fallback). Never commits or pushes if hooks fail.
---

# Git Workflow

Safe commit, push, PR, and issue creation with full pre-hook enforcement. This skill wraps the git lifecycle — it runs every available check before touching the remote and never bypasses failures.

Complementary to `deep-review-workflow` (which handles autonomous code fixing). This skill handles the safe lifecycle: commit → push → PR/issue creation.

## Core Rules (Non-Negotiable)

1. **Never use `--no-verify`** — if a hook fails, stop and report.
2. **Never force push** — unless user explicitly requests and confirms twice.
3. **Never push to main/master directly** — a feature branch is required.
4. **Use GitHub MCP tools for PRs and issues** — prefer MCP (`github_create_pull_request`, `github_create_issue`, etc.) over `gh` CLI. Fall back to `gh` CLI only if MCP is unavailable.
5. **Enforce LOC cap per project config** — read `.github/` for any size policy, fall back to SOP default (200 LOC).
6. **Conventional commits** — follow `commitlint` config if present, else use best practices (`type(scope): description`).

## When to Use

- The user asks to commit, push, create a PR, or create a GitHub issue.
- The user runs `/git commit`, `/git push`, `/git pr`, or `/git issue`.
- The user wants to verify their branch is ready before pushing.
- The user is starting new work and needs an issue drafted (Gate 1).
- The user needs a PR body filled from the project template.

## Slash Command Contract

`/git` is the user-facing command for this skill. The command should delegate to a subagent so git status, diffs, hooks, and CLI output stay out of the main conversation context.

Supported forms:

- `/git commit ...` — inspect changes, propose commit grouping and messages, ask for approval, then commit only approved groups.
- `/git push ...` — run the pre-push safety gate and push lifecycle.
- `/git pr ...` — run the full push + PR lifecycle using project templates, MCP tools, or `gh pr create`.
- `/git issue ...` — create a GitHub issue using project templates, MCP tools, or `gh issue create`.

For `/git pr`, always use the PR workflow in this skill. Do not use a separate git command flow.

## Prerequisites Check

Before any action, verify:

```bash
# Check we are in a git repo
git rev-parse --show-toplevel 2>&1
# If not a repo, output error and stop.

# Identify current branch
git branch --show-current
# If on main/master, refuse to push and suggest creating a branch.
```

### GitHub Tool Availability

Detect which GitHub interface is available (in priority order):

1. **GitHub MCP tools** (preferred) — check if MCP tools like `github_create_pull_request`, `github_create_issue`, `github_list_issues` are available in the current session. If yes, use these for all GitHub API operations.
2. **`gh` CLI** (fallback) — check `gh auth status 2>&1`. If authenticated, use for GitHub operations.
3. **Neither available** — fall back to generating filled templates for manual use. Never block entirely — always provide the content.

Record which interface is in use for the session.

---

## Workflow Phases

Execute in order. **Do not skip phases.** If any phase fails, stop and report.

### Phase 1 — Project Detection

Gather project context before acting:

```bash
# Repo root
REPO_ROOT=$(git rev-parse --show-toplevel)

# Current branch
BRANCH=$(git branch --show-current)

# Remote default branch
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
# Fallback if remote not available
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

# Detect .github/ structure
ls -la "$REPO_ROOT/.github/" 2>/dev/null
ls -la "$REPO_ROOT/.github/ISSUE_TEMPLATE/" 2>/dev/null
ls -la "$REPO_ROOT/.github/workflows/" 2>/dev/null

# Detect hooks
ls -la "$REPO_ROOT/.husky/" 2>/dev/null
ls -la "$REPO_ROOT/.git/hooks/" 2>/dev/null

# Detect commitlint
grep -q "commitlint" "$REPO_ROOT/package.json" 2>/dev/null && echo "commitlint: yes"
[ -f "$REPO_ROOT/commitlint.config.js" ] && echo "commitlint config: yes"
[ -f "$REPO_ROOT/commitlint.config.ts" ] && echo "commitlint config: yes"

# Detect lint-staged
grep -q "lint-staged" "$REPO_ROOT/package.json" 2>/dev/null && echo "lint-staged: yes"

# Detect LOC policy
# Check for any custom size policy in .github/ or CLAUDE.md
LOC_CAP=200  # default from SOP
# Override if project defines a different cap
```

Record findings:
- Has `.github/` directory? (yes/no)
- Has PR template? (path if found)
- Has issue templates? (paths if found)
- Has husky hooks? (which ones: pre-commit, pre-push, commit-msg)
- Has commitlint? (yes/no)
- Has lint-staged? (yes/no)
- LOC cap (default 200, or project override)

---

### Phase 2 — Pre-Commit Safety Gate

**Goal:** Ensure the working tree is clean, staged changes pass all checks, and the commit message is valid.

#### 2a. Run Pre-Commit Hook

```bash
# If husky is installed and .husky/pre-commit exists
if [ -f "$REPO_ROOT/.husky/pre-commit" ]; then
  npx husky run "$REPO_ROOT/.husky/pre-commit"
  # Capture exit code
  # If non-zero: BLOCK — output the failure log and stop
fi

# If no husky but lint-staged exists
if grep -q "lint-staged" "$REPO_ROOT/package.json" 2>/dev/null; then
  npx lint-staged
  # Capture exit code
  # If non-zero: BLOCK
fi
```

**If any pre-commit check fails:**
- Output the full error log
- Status: `blocked`
- Phase: `pre-commit`
- Stop all further action

#### 2b. Propose Commit Groups and Messages

Before staging anything, inspect the working tree and diff to decide whether the changes belong in one commit or multiple commits.

Rules:
- Group files by coherent purpose, not by file type.
- Keep unrelated docs/config/code changes in separate commits when practical.
- Never include unreviewed unrelated files.
- If the user's wording clearly scopes the commit, honor that scope.
- If uncertain whether a file belongs, ask before staging it.

Present the proposed grouping and exact commit message before committing:

```text
Proposed commit 1:
Message: chore: add agent config setup installer
Files:
- setup-agent-configs.sh
- README.md
- ai-code-agents/README.md

Use this commit message and file group? Reply yes, or tell me what to change.
```

If the user asks for changes, revise the grouping/message and ask again. Repeat until the user approves. Do not commit until the user approves the exact group and message.

#### 2c. Validate Commit Message

If `commitlint` is configured, validate the message format before committing:

```bash
# Dry-run validation
echo "$COMMIT_MSG" | npx commitlint 2>&1
# If non-zero: suggest corrected format and ask user to confirm
```

Conventional commit format (fallback if no commitlint):
```
type(scope): description

# Types: feat, fix, refactor, docs, test, chore, ci, perf, style, build
# Scope: optional, lowercase
# Description: imperative mood, lowercase, no period, <=72 chars
```

#### 2d. Commit

```bash
# Stage only the approved files for the current commit group
git add -- <approved-files>
git commit -m "$COMMIT_MSG"
# Verify exit code 0
```

If commit fails (e.g., pre-commit hook intercepted), report the failure and stop.

---

### Phase 3 — Pre-Push Safety Gate

**Goal:** Ensure all tests, type checks, and builds pass before pushing.

#### 3a. Run Pre-Push Hook

```bash
if [ -f "$REPO_ROOT/.husky/pre-push" ]; then
  npx husky run "$REPO_ROOT/.husky/pre-push"
  # If non-zero: BLOCK — output failure and stop
fi
```

#### 3b. Fallback Checks (if no pre-push hook)

If no pre-push hook exists, run available checks from `package.json` scripts:

```bash
# Check what scripts are available
cat "$REPO_ROOT/package.json" | grep -A 20 '"scripts"' 2>/dev/null

# Run in order (only if script exists):
# 1. typecheck / type-check
npm run typecheck 2>&1 || npm run type-check 2>&1
# If non-zero: BLOCK

# 2. lint
npm run lint 2>&1
# If non-zero: BLOCK

# 3. test
npm test 2>&1
# If non-zero: BLOCK

# 4. build (only if explicitly requested or project has no CI)
npm run build 2>&1
# If non-zero: BLOCK
```

**If any check fails:**
- Output the full error log
- Status: `blocked`
- Phase: `pre-push`
- Stop all further action

---

### Phase 4 — Push

```bash
# Standard push (never force unless explicitly confirmed)
git push -u origin "$BRANCH"

# Verify push succeeded
if [ $? -ne 0 ]; then
  # Check if it was a non-fast-forward (diverged history)
  git status
  # Report the issue — do NOT retry with force
  # Ask user how to proceed
fi
```

---

### Phase 5 — PR Creation

**Goal:** Create a PR using the project's template, filled with accurate information.

#### 5a. Detect PR Template

```bash
# Check for template (case variations)
PR_TEMPLATE=""
for path in \
  "$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md" \
  "$REPO_ROOT/.github/pull_request_template.md" \
  "$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE/default.md"; do
  if [ -f "$path" ]; then
    PR_TEMPLATE="$path"
    break
  fi
done

if [ -n "$PR_TEMPLATE" ]; then
  echo "PR template found: $PR_TEMPLATE"
  cat "$PR_TEMPLATE"
else
  echo "No PR template found — using SOP work-pr.md template"
fi
```

#### 5b. Check LOC Count

```bash
# Get diff stats against default branch
DIFF_STAT=$(git diff --stat "origin/$DEFAULT_BRANCH...HEAD" 2>/dev/null || git diff --stat "$DEFAULT_BRANCH...HEAD" 2>/dev/null)
INSERTIONS=$(echo "$DIFF_STAT" | tail -1 | grep -oP '\d+(?= insertion)' || echo 0)
DELETIONS=$(echo "$DIFF_STAT" | tail -1 | grep -oP '\d+(?= deletion)' || echo 0)
TOTAL_LOC=$((INSERTIONS + DELETIONS))

echo "LOC: +$INSERTIONS -$DELETIONS = $TOTAL_LOC (cap: $LOC_CAP)"

if [ "$TOTAL_LOC" -gt "$LOC_CAP" ]; then
  echo "WARNING: PR exceeds $LOC_CAP LOC cap"
  echo "Split into smaller PRs or provide a split plan before proceeding."
  # If project enforces (not just warns), stop here and require split plan
  # Default behavior: WARN and ask user to confirm or provide split plan
fi
```

#### 5c. Fill Template

Use the project's PR template. If none exists, use this SOP template:

```markdown
- Links to: #<issue_number>
- Gate 1: <link to approval comment>
- Gate 2: <link to approval comment>

## What changed
<!-- 3–5 bullets explaining the change -->

## Why this is minimal
<!-- One sentence justifying why this is the smallest viable change -->

## Verification
- [ ] Builds: `<command>`
- [ ] Tests: `<command>`
- [ ] Lint/Typecheck: `<command>`
- [ ] Manual verification: `<steps>`

## AI Usage
- [ ] AI used for: <design / code / tests / docs>
- [ ] Manual verification: <what was checked>

## Size Check
- [ ] ≤200 LOC (PRs over 200 LOC will be closed without review)
```

Fill in from context:
- What changed: summarize the diff
- Why minimal: explain the approach
- Verification: list the commands that were run
- AI usage: disclose what AI was used for
- Size: check the actual LOC

#### 5d. Create PR

**Preferred: GitHub MCP** — use `github_create_pull_request` with the filled template:

```
github_create_pull_request(
  owner: "<org>",
  repo: "<repo>",
  title: "$PR_TITLE",
  body: "$PR_BODY",
  head: "$BRANCH",
  base: "$DEFAULT_BRANCH"
)
```

**Fallback: `gh` CLI** — if MCP is unavailable:

```bash
gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --base "$DEFAULT_BRANCH" \
  --head "$BRANCH"
```

If neither is available, output the filled template and the command to run manually.

---

### Phase 6 — Issue Creation (When Requested)

**Goal:** Create a GitHub issue using the project's template or SOP Gate 1 format.

#### 6a. Detect Issue Template

```bash
# Check for issue templates
ISSUE_TEMPLATES=$(ls "$REPO_ROOT/.github/ISSUE_TEMPLATE/"*.yml 2>/dev/null || ls "$REPO_ROOT/.github/ISSUE_TEMPLATE/"*.yaml 2>/dev/null)

if [ -n "$ISSUE_TEMPLATES" ]; then
  echo "Issue templates found:"
  echo "$ISSUE_TEMPLATES"
  # Parse the first matching template for field structure
  cat "$(echo "$ISSUE_TEMPLATES" | head -1)"
else
  echo "No issue template found — using SOP work-issue.md template"
fi
```

#### 6b. Fill Template

Use the project's issue template if available. If none, use SOP Gate 1 template:

```markdown
## Problem
<!-- What exactly is wrong / missing -->

## Why it matters
<!-- Impact and who is affected -->

## Acceptance Criteria
<!-- Testable criteria. Format: "Given X, when Y, then Z" -->

## Verification Plan
- [ ] Unit tests
- [ ] Integration tests
- [ ] Manual verification

## Size
- [ ] ≤50 LOC
- [ ] 51–100 LOC
- [ ] 101–200 LOC
- [ ] >200 LOC (must split)

## Split Plan (only if >200 LOC)
<!-- PR 1, PR 2, PR 3 — each verifiable independently -->

## File Changes
<!-- List files to modify -->

## Minimal Approach
<!-- One paragraph describing the smallest solution that satisfies acceptance -->

## Approvals
- [ ] Gate 1 (Definition of Ready)
- [ ] Gate 2 (Approach Approved)
```

Fill in from the user's description. If the user hasn't provided enough detail for acceptance criteria or test plan, ask before creating.

#### 6c. Create Issue

**Preferred: GitHub MCP** — use `github_create_issue` with the filled template:

```
github_create_issue(
  owner: "<org>",
  repo: "<repo>",
  title: "$ISSUE_TITLE",
  body: "$ISSUE_BODY"
)
```

**Fallback: `gh` CLI** — if MCP is unavailable:

```bash
gh issue create \
  --title "$ISSUE_TITLE" \
  --body "$ISSUE_BODY"
```

If neither is available, output the filled template and the command to run manually.

---

## Output Format

Return this JSON object after each action:

```json
{
  "status": "success|blocked|needs_input",
  "phase": "detection|pre-commit|commit|pre-push|push|pr|issue",
  "summary": "Human-readable summary of what happened",
  "checks_passed": ["pre-commit hook", "typecheck", "lint"],
  "checks_failed": ["test — 3 failures in src/lib/"],
  "loc_count": {
    "insertions": 0,
    "deletions": 0,
    "total": 0,
    "cap": 200,
    "within_cap": true
  },
  "pr_url": null,
  "issue_url": null,
  "template_used": "project|.github|sop",
  "next_steps": ["Fix failing tests", "Re-run git-workflow skill"]
}
```

---

## Quick Reference

| Action | What happens |
|--------|-------------|
| **Commit** | Phases 1 → 2 (detect → pre-commit → commit) |
| **Push** | Phases 1 → 4 (detect → pre-commit → commit → pre-push → push) |
| **Create PR** | Phases 1 → 5 (full lifecycle + PR creation via MCP or gh) |
| **Create Issue** | Phase 6 only (detect template → fill → create via MCP or gh) |
| **Full lifecycle** | Phases 1 → 6 (commit → push → PR → optional issue) |

---

## Hook Failure Reference

Common pre-commit/pre-push failures and how to handle them:

| Failure | Action |
|---------|--------|
| Lint errors | Run linter fixer, re-stage, retry |
| Type errors | Report file:line, stop |
| Test failures | Report failing tests, stop |
| Coverage below threshold | Report current vs required, stop |
| Commit message format | Suggest corrected format |
| Prisma schema without migration | Run `make db:migrate:create`, retry |
| Agent docs out of sync | Run sync, retry |
| `.env` file staged | Unstage `.env`, stop |
| Merge conflict markers | Report files with conflicts, stop |

**Never skip past a failure. Fix it or ask the user to fix it.**

---

## Safety & Limits

- Modify only tracked git files. Never modify `.git/` internals.
- Never store or request secrets in PR bodies or issue descriptions.
- Never use `--no-verify` for any git operation.
- Never force push without explicit user confirmation.
- Prefer GitHub MCP tools over `gh` CLI for GitHub API operations. Fall back to `gh` CLI only if MCP is unavailable.
- If neither MCP nor `gh` CLI is available, always provide the filled template content so the user can proceed manually.
- If the project has CODEOWNERS, note the required reviewers in the PR summary but do not add them automatically (let the user decide).
