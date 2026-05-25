---
name: deep-review-workflow
description: Use when reviewing and remediating critical code issues including security vulnerabilities, bugs, code smells, and architectural problems.
---

# Deep Review Workflow

This skill provides a complete workflow for detecting AND fixing security vulnerabilities, bugs, code smells, and tight coupling issues.

## Autonomous Operation Mode

**You have been tasked to fix issues autonomously.** The user trusts you to:

1. **Work independently** - The user may be away and unavailable for questions
2. **Follow this workflow in order** - Each phase builds on the previous
3. **Create a feature branch** - Never commit directly to main/master
4. **Fix issues with best practices** - Apply clean code principles
5. **Research when uncertain** - Use available documentation, web search, or code context tools for best practices or unfamiliar patterns
6. **Try your best** - The user trusts your judgment; make reasonable decisions

**If you are uncertain about something:**
- Search for documentation or examples using available research tools
- Follow existing patterns in the codebase
- Choose the simpler, safer option
- Document your reasoning in commit messages

## When to Use

Use this skill when:
- Tasked with fixing bugs, security issues, or code quality problems
- Reviewing and remediating a PR or feature branch
- Performing security hardening before release
- Cleaning up technical debt hotspots
- The user is unavailable and expects autonomous fixes

## Workflow Overview

Follow these steps in order - do not skip phases:

### Phase 1: Scope Definition

Before reviewing, define what you're examining:

1. **Identify the target** - Specific files, a PR, a feature branch, or a module
2. **Gather context** - What does this code do? What's its criticality?
3. **Check history** - Recent changes, known issues, past incidents
4. **Set review depth** - Quick scan vs. deep audit

**Scope deliverable:** Clear understanding of:
- What code is being reviewed
- Business criticality level
- Time constraints (if any)
- Areas of highest risk

### Phase 2: Security Scan

Check for vulnerabilities that could be exploited:

1. **Input validation** - Find unsanitized user input
   - SQL injection vectors
   - Command injection
   - Path traversal
   - XSS opportunities

2. **Authentication/Authorization**
   - Missing auth checks
   - Broken access control
   - Session handling issues
   - Privilege escalation paths

3. **Secrets and credentials**
   - Hardcoded API keys
   - Leaked tokens in logs
   - Insecure storage

4. **Dependencies**
   - Known CVEs in packages
   - Outdated vulnerable versions

**Security deliverable:** List of findings with:
- Severity (Critical/High/Medium/Low)
- CWE/OWASP reference where applicable
- File:line locations
- Exploit scenario

### Phase 3: Bug Detection

Find logic errors and potential runtime failures:

1. **Null/undefined access**
   - Unguarded property access
   - Missing null checks on external data

2. **Error handling**
   - Empty catch blocks
   - Swallowed exceptions
   - Missing error propagation

3. **Resource management**
   - Unclosed connections/files
   - Memory leaks
   - Missing cleanup in finally blocks

4. **Edge cases**
   - Off-by-one errors
   - Empty collection handling
   - Boundary conditions

5. **Concurrency issues**
   - Race conditions
   - Shared mutable state
   - Missing synchronization

**Bug deliverable:** List of findings with:
- Likelihood of occurrence
- Impact if triggered
- Reproduction scenario
- File:line locations

### Phase 4: Code Smell Analysis

Identify maintainability issues:

1. **Size and complexity**
   - God classes (>500 lines, >20 methods)
   - Long functions (>100 lines)
   - Deep nesting (>4 levels)
   - Cyclomatic complexity hotspots

2. **Design smells**
   - Long parameter lists (>5 params)
   - Feature envy (method uses other class more than own)
   - Primitive obsession
   - Data clumps

3. **Duplication**
   - Copy-paste code blocks
   - Similar logic in multiple places
   - Opportunities for extraction

4. **Naming and clarity**
   - Misleading names
   - Magic numbers/strings
   - Unclear intent

**Smell deliverable:** List of findings with:
- Severity (High/Medium/Low)
- Refactoring suggestion
- Estimated complexity to fix

### Phase 5: Coupling Analysis

Detect architectural issues:

1. **Dependency problems**
   - Circular imports/dependencies
   - Layer violations (UI calling DB directly)
   - Missing abstraction boundaries

2. **Hardcoded dependencies**
   - Classes instantiating own dependencies
   - Static method abuse
   - Global state usage

3. **Interface issues**
   - Leaky abstractions
   - Concrete dependencies where interfaces fit
   - Violation of dependency inversion

4. **Change impact**
   - Shotgun surgery indicators
   - Modules that change together
   - High fan-in/fan-out

**Coupling deliverable:** Dependency diagram notes with:
- Problematic relationships
- Suggested decoupling points
- Blast radius assessment

### Phase 6: Branch Setup

Before making any fixes, set up proper git workflow:

1. **Check current state** - Inspect `git status`, `git diff`, and recent history; do not overwrite unrelated work
2. **Create feature branch** - Branch from main/master unless the user already provided the correct branch
   ```bash
   git checkout -b fix/deep-review-$(date +%Y%m%d)
   ```
3. **Verify branch** - Confirm you're on the new branch before editing

### Phase 7: Fix Implementation

Work through findings by priority (P0 first, then P1):

1. **Fix one issue at a time** - Don't batch unrelated fixes
2. **Track progress** - Track each fix as a todo item using available planning tools or a local checklist
3. **Research if needed** - Use available research tools for unfamiliar patterns
4. **Follow existing patterns** - Match codebase style
5. **Commit only when requested** - If commits are requested, use small, atomic commits with clear messages
   ```bash
   git add <files>
   git commit -m "fix(security): sanitize user input in auth handler"
   ```

**Implementation rules:**
- P0 (Critical security/bugs): Fix all of these
- P1 (Major issues): Fix as many as reasonable
- P2 (Minor/architectural): Document for later, fix only if quick

### Phase 8: Quality Control

After all fixes, verify the changes:

1. **Run type checker** - `npx tsc --noEmit` or equivalent
2. **Run linter** - On changed files only
3. **Run tests** - If test suite exists
4. **Let pre-commit hooks run** - Never use `--no-verify`

Fix any failures before proceeding.

### Phase 9: Report Assembly

Create structured report document:

1. **Create report** - Save to `reports/` or `.beads/reviews/`
2. **Executive summary** - Top 5-10 critical findings
3. **What was fixed** - List of remediated issues
4. **What remains** - Issues deferred for later
5. **Detailed findings by category** - Security, Bugs, Smells, Coupling

**Report template:**

```markdown
# Deep Review Report: [Target Description]

**Date:** YYYY-MM-DD
**Scope:** [Files/PR/Module reviewed]
**Branch:** fix/deep-review-YYYYMMDD
**Status:** [Fixed / Partially Fixed / Documented Only]

## Executive Summary

Issues found: X total (Y fixed, Z deferred)

| Priority | Category | Finding | Status | Location |
|----------|----------|---------|--------|----------|
| P0 | Security | Description | FIXED | file:line |
| P1 | Bug | Description | FIXED | file:line |
| P2 | Smell | Description | DEFERRED | file:line |

## Fixes Applied

### [S-01] Finding Title - FIXED
- **Severity:** Critical
- **Location:** `file/path:line`
- **Issue:** What was wrong
- **Fix:** What was changed
- **Commit:** abc1234

## Deferred Issues

### [C-01] Coupling Issue - DEFERRED
- **Severity:** Medium
- **Location:** `file/path:line`
- **Issue:** What needs work
- **Reason deferred:** Requires architectural discussion
- **Recommendation:** Future refactoring ticket

## Quality Control Results

- Type check: PASSED
- Linter: PASSED
- Tests: PASSED
- Pre-commit hooks: PASSED
```

### Phase 10: Push and PR

Finalize the changes:

1. **Push the branch**
   ```bash
   git push -u origin fix/deep-review-$(date +%Y%m%d)
   ```

2. **Create PR** with detailed description
   ```bash
   gh pr create --title "fix: Deep review remediation" --body "$(cat <<'EOF'
   ## Summary
   Automated deep review and fix of security, bug, and code quality issues.

   ## Fixes Applied
   - [List each fix with commit reference]

   ## Deferred Issues
   - [List issues documented but not fixed]

   ## Quality Control
   - [x] Type check passed
   - [x] Linter passed
   - [x] Tests passed

   ## Report
   See `reports/deep-review-YYYYMMDD.md` for full details.
   EOF
   )"
   ```

3. **Provide PR link** to user when they return

## Detection Patterns

**Security red flags:**
```
# Secrets
grep -r "password\s*=" --include="*.{ts,js,py}"
grep -r "api[_-]?key" --include="*.{ts,js,py}"

# SQL injection
grep -r "execute.*\$\|execute.*+" --include="*.py"
grep -r "query.*\`.*\$" --include="*.{ts,js}"

# Command injection
grep -r "exec\(|spawn\(|system\(" --include="*.{ts,js,py}"
```

**Bug patterns:**
```
# Empty catch
grep -r "catch.*{[\s]*}" --include="*.{ts,js}"

# Potential null access
grep -r "\.\w+\.\w+\.\w+" --include="*.{ts,js}"
```

**Smell patterns:**
```
# Long files
find . -name "*.ts" -exec wc -l {} + | sort -n

# TODO/FIXME debt
grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.{ts,js,py}"
```

## Common Pitfalls

**Avoid these mistakes:**

- **Surface-level review** - Only checking syntax, missing logic issues
- **No security focus** - Skipping vulnerability assessment
- **Ignoring context** - Not understanding what the code does
- **Vague findings** - "This looks bad" without specifics
- **No prioritization** - Treating all issues as equal
- **Committing to main** - Always use a feature branch
- **Big bang commits** - Commit each fix separately
- **Skipping QC** - Always run type check and linter before PR
- **Not using Exa** - When uncertain, search for best practices

## Quality Checklist

Before considering work complete:

- [ ] Feature branch created - Not on main/master
- [ ] Security scan completed - All input paths checked
- [ ] Bug detection done - Error handling and edge cases reviewed
- [ ] Smell analysis finished - Complexity hotspots identified
- [ ] Coupling checked - Dependencies mapped
- [ ] P0 issues fixed - All critical issues remediated
- [ ] P1 issues addressed - Fixed or documented with reasoning
- [ ] Each fix committed - Atomic commits with clear messages
- [ ] Type check passes - No errors
- [ ] Linter passes - No violations
- [ ] Tests pass - If test suite exists
- [ ] Report created - Structured findings document
- [ ] Branch pushed - To remote origin
- [ ] PR created - With detailed description
- [ ] PR link ready - For user when they return
