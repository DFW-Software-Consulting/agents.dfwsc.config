# Claude Code Commands

Custom slash commands for Claude Code context engineering workflow.

## Installation

Copy these `.md` files to your `~/.claude/commands/` directory:

```bash
cp *.md ~/.claude/commands/
```

## Available Commands

### `/cc-pn` - Plan

Generates a concrete implementation plan from a research document.

**Usage:** `/cc-pn`

**Features:**
- Reads research from `memory-bank/research/`
- Validates freshness against git state
- Creates structured plan with milestones, tasks, gates
- Outputs to `memory-bank/plan/`
- Deploys context-synthesis and codebase-analyzer subagents

**Plan Structure:**
- Goal and scope
- Deliverables (DoD) and Readiness (DoR)
- Milestones (Architecture, Core, Tests, Packaging, Docs)
- Work breakdown with acceptance tests
- Risks and mitigations
- Test strategy

### `/ce-cm` - Context Compact

Prepares context for compaction when approaching token limits. Preserves essential information for task continuation.

**Usage:** `/ce-cm [current-task-description]`

**Output:** Structured summary including:
- Task state and completed work
- Technical context (files, patterns, decisions)
- Next steps and remaining work
- Key references (branch, issue IDs, commands)

### `/ce-ex` - Execute Plan

Executes an implementation plan with gated checks, atomic commits, and validation.

**Usage:** `/ce-ex`

**Features:**
- Reads plan from `memory-bank/plan/` directory
- Creates rollback point before execution
- Implements tasks atomically with commits
- Enforces quality gates (tests, type checks, linting)
- Generates execution log in `memory-bank/execute/`
- Deploys QA subagents after completion

## Workflow

These commands are part of the Context Engineer workflow:

1. **Research** - Gather information and requirements
2. **Plan** (`/cc-pn`) - Create implementation plan with tasks and gates
3. **Execute** (`/ce-ex`) - Implement with validation and logging
4. **Compact** (`/ce-cm`) - Preserve context when needed
