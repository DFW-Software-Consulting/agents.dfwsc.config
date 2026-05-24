---
name: route-audit
description: Use when auditing a route's full dependency graph in Emmut Properties Management — map files, check anti-patterns across API/backend, frontend, React patterns, cache config, TypeScript, and code quality. One route per pass.
---

# Route Domain Audit

Full-stack audit of a single route and its complete dependency graph in the Emmut Properties Management codebase (Next.js 15 App Router, React 19, TanStack Query v5, Prisma 6, ShadCN/Radix, TailwindCSS 4, TypeScript 5.x strict mode).

## When to Use

- Asked to audit, review, or analyze a specific route (e.g. `/reservations/[id]`)
- Asked to identify anti-patterns, bugs, or technical debt in a feature area
- Before making significant changes to an existing route

## Required Reading

Before starting: read `.claude/CLAUDE.md`, `.claude/architecture.md`, `.claude/backend-patterns.md`, `.claude/frontend-styles.md`, `.claude/code-review.md`, and AGENTS.md.

## Input

One route path (e.g. `/reservations/[id]` or `/api/properties/:id/channels`). Optionally a specific focus area (API/frontend/cache/TS).

## Steps

Most phases delegate to subagents to keep the main context lean. The main agent orchestrates, reads required docs first, then delegates.

### 0. Required Reading (main agent)

Read `.claude/CLAUDE.md`, `.claude/architecture.md`, `.claude/backend-patterns.md`, `.claude/frontend-styles.md`, `.claude/code-review.md`, and AGENTS.md before dispatching any subagent.

### 1. Map the Dependency Graph → `codebase-locator`

Delegate to `codebase-locator` subagent with:

- The route path (e.g. `/reservations/[id]`)
- Instructions to find the route entrypoint (`src/app/.../page.tsx` or API route handler)
- Then trace the feature slice it pulls from (`src/features/<slice>/...`)
- Then trace to every component, hook, service, schema, mapper, constant touched
- Then find test files covering the above

Return: a flat list of all file paths with a short description of each file's role.

### 2. Cross-Impact Analysis → `codebase-analyzer`

Feed the file list from Step 1 to `codebase-analyzer` subagent.

For each file, grep for imports/usages of that file/symbol outside the route to determine blast radius. Check dynamic imports and string-based references too.

Return: per-file list of cross-references outside the route's own graph.

### 3. Apply Anti-Pattern Checklist → `antipattern-sniffer`

Feed the file list from Step 1 and the anti-pattern checklist below to `antipattern-sniffer` subagent.

Return: findings grouped by file, with rule violated, severity, and line references. Exclude files with zero findings.

### 4. Dead Code Verification (main agent)

Before claiming any code dead: grep for the symbol, check dynamic imports, string-based references (query keys, event names), and tests. This is cheap enough to keep in the main agent.

### 5. Synthesize Findings Report (main agent)

Merge results from all subagents into a single findings report. Group by severity (Critical/High/Medium/Low). Critical/High first. Out-of-scope findings go in a "Noted for later" section. Stop and wait for approval before any edits.

### 6. Verification (after approved changes) → `typecheck` / `test-runner`

After edits are approved and applied, delegate verification:
- `typecheck` subagent for TypeScript compilation
- `test-runner` subagent for relevant tests

## Anti-Pattern Checklist

### API / Backend

- `NextResponse.json()` in normal routes — use response builders from `@/lib/api`
- Direct `prisma.*` in routes or components — must go through service layer
- Mutation route missing `checkRateLimit(request, limiter)`
- `catch` block missing `handleApiError(error, { context })`
- `@/lib/api/auth-middleware` imported outside test mocks
- Protected route missing auth wrapper
- Route handler GET assumes implicit caching (Next.js 15 GETs are no longer cached by default)
- `params`/`searchParams` used as plain objects in page components (Next.js 15: they're Promises — must await)
- Dynamic API used in a segment expected to be static (`cookies`/`headers` forces full dynamic)
- Server Action skipping auth/authz/validation
- Multiple `prisma.*` calls that could be `Promise.all`'d
- N+1 risk: `findMany` followed by per-row `findUnique` in a loop
- Long-lived interactive transactions (>1s)
- Prisma `include` returning more relations than the UI uses (prefer `select` for hot paths)

### Frontend / Client

- Direct `fetch()` in hooks — use `fetchApiData`/`mutateApi` from `@/lib/api/fetch-utils`
- `@/lib/api` barrel imported from a client component (server-only)
- Direct sonner toast — use `@/lib/logger/toast-logger`
- Plain `<Dialog>` for new dialogs — use `ResponsiveDialog`
- Hardcoded query keys — use `src/lib/query/query-keys.ts`
- Manual `invalidateQueries` chains — use invalidation helpers
- `toLocaleDateString` on date-only UTC — use `formatUTCDate()`
- Raw `cpropname` for display — use `resolvePropertyDisplayName()`
- High-impact send (email/SMS/payment/webhook) bypassing `usePendingSends().enqueueSend()`
- `isLoading` on a query (renamed to `isPending` in v5)
- `cacheTime` (v4 name) instead of `gcTime` in QueryClient config
- QueryClient instantiated inside a component
- Query missing `enabled` guard when params are conditional
- Inline object/array literals in `queryKey` causing cache misses
- Loading UI implemented manually when `useSuspenseQuery` would give type-safe `data: T`

### React Patterns (Compiler + React 19 Hooks)

- `useEffect` for data fetching — use `useQuery`/`useSuspenseQuery`/Server Component
- `useEffect` for derived state — compute during render or use `useMemo`
- `useEffect` chains that `setState` from props
- `useEffect` for form submission state — use `useActionState`
- Manual optimistic update with `useState` + rollback — use `useOptimistic`
- Manual loading spinner inside a form — use `useFormStatus`
- Manual `startTransition` — use `useTransition`
- Subscribing to external store via `useEffect` — use `useSyncExternalStore`
- Manual `useMemo`/`useCallback` — React Compiler handles this automatically unless memo is feeding `useEffect` deps, integrating with a ref-equality library, or component has `"use no memo"`
- `React.memo` wrapping every export — same reasoning
- `useReducer` ignored when 3+ related state vars exist

### Cache Settings (TanStack Query v5 Tiers)

Flag mismatches between data volatility and cache config:

- `staleTime: 0` on stable reference data (statuses, types) — set 10min+
- `staleTime: Infinity` on user-mutable data — must invalidate on mutation
- `gcTime < staleTime` — bug (data evicted while still fresh)
- Live/realtime data with `refetchInterval` but also high `staleTime`

Recommended tiers:
- `0` — live/critical (payments, reservation conflicts)
- `30_000` — user-generated content (notes, comments)
- `120_000` — profile / preferences
- `600_000+` — reference data (statuses, property lists)

### TypeScript (5.x + Strict Mode)

- `as` casts where `satisfies` would preserve narrower inference
- `any` — must be `unknown` + narrowing
- Optional property typed `{ x?: T }` when intent is `T | undefined`
- Array/record index access without undefined check (`noUncheckedIndexedAccess`)
- String IDs that should be branded types
- Floating promises (missing `await` or `.catch`)
- `interface` vs `type` inconsistency within a feature
- Enum-like union typed as `string` instead of literal union
- `satisfies` operator usage: prefer `as const satisfies` over raw `as` for preserving literal types

### Code Quality

- Inline mappers — use `src/lib/mappers/` or `src/services/mappers/`
- Hardcoded status/rate/source values — use `src/lib/constants/`
- Schemas duplicated across features — consolidate
- Tests asserting implementation details, not behavior
- Comments explaining WHAT instead of WHY
- "Just in case" error handling for impossible scenarios

## Findings Report Format

```
### [Critical|High|Medium|Low] <title>

File: path/to/file.tsx:42-58
Issue: <one sentence>
Why it matters: <bug class | perf | security | maintainability | DX>
Cross-impact: <list of affected files>
Fix: <surgical proposed change>
Verification: <test name, grep result, or type check>
```

Severity definitions:
- **Critical**: bug, security, data integrity, broken Next.js 15 contract
- **High**: anti-pattern causing future bugs (wrong cache, missing rate limit, unsafe Server Action, params-not-awaited)
- **Medium**: best-practice drift (useEffect → useQuery, manual memo in Compiler era)
- **Low**: dead code, duplication, cleanup, comment hygiene

## Rules

- Investigation-only until user approves findings. No edits.
- One route per pass. No "while we're at it" cleanup.
- No commits or pushes without explicit approval.
- Do NOT recommend wholesale Server Actions migration — this repo's convention is Route Handlers + service layer. Flag isolated Server Action opportunities only if they materially simplify a flow.
- Before recommending React Compiler memo removal: confirm the compiler is enabled in `next.config`.
- After approved edits, delegate verification to `typecheck` and `test-runner` subagents (not main agent — see Step 6).
