# OpenCode Subagents

Subagents are specialized AI agents that run with isolated context and focused instructions. The main agent delegates to them for specific tasks, keeping the main conversation clean and preventing context bloat.

## How to Use

In OpenCode, reference a subagent by name when asking the main agent to do something:

```
use the database-optimizer agent to review this query
```

Or the main agent will automatically delegate to the right subagent based on the task.

## Research Agents (Read-Only)

These agents only read — no edits, no suggestions, just structured reports. They run on `minimax-m2.7` to keep costs low.

| Agent | When to use it |
|---|---|
| `codebase-locator` | "Where does X live?" — finds files, dirs, entry points by name or purpose |
| `codebase-analyzer` | "How does X work?" — maps function signatures, data flow, dependencies |
| `context-synthesis` | "How do X and Y relate?" — traces imports, cross-cutting concerns, shared patterns |
| `antipattern-sniffer` | "Is this code clean?" — audits for antipatterns, code smells, bad practices. Run before committing |

## Specialist Agents (Implementation)

These agents design, build, and fix things. They run on `gpt-5.3-codex` for stronger reasoning.

| Agent | When to use it |
|---|---|
| `backend-architect` | Designing APIs, service boundaries, scalability tradeoffs |
| `frontend-developer` | Bundle optimization, Core Web Vitals, accessibility, React/Vue/Svelte work |
| `cloud-architect` | AWS/GCP/Azure infra design, cost review, IAM, networking |
| `database-optimizer` | Slow queries, EXPLAIN plans, indexes, N+1 fixes, schema review |
| `test-automator` | Writing unit/integration/E2E/load tests, test strategy |
| `devops-troubleshooter` | Production incidents, observability setup, SLOs, alerting |
| `deployment-engineer` | CI/CD pipelines, Docker images, blue-green/canary releases |
| `mobile-developer` | iOS/Android/React Native/Flutter — startup time, memory, battery |
| `performance-engineer` | Profiling, bottleneck identification, hot path optimization |

## Model Assignment

| Agent group | Model |
|---|---|
| Research agents (4) | `opencode/minimax-m2.7` |
| Specialist agents (9) | `opencode/gpt-5.3-codex` |
| Default (main agent) | `openrouter/minimax-m2.5:free` |

Model assignments are configured in [`../opencode.json`](../opencode.json) under the `agent` block.
