---
name: route-audit
description: Use when auditing a route's full dependency graph in Emmut Properties Management — map files, check anti-patterns across API/backend, frontend, React patterns, cache config, TypeScript, and code quality. One route per pass.
---

# Route Domain Audit (Claude)

Full-stack audit of a single route and its complete dependency graph in the Emmut Properties Management codebase (Next.js 15 App Router, React 19, TanStack Query v5, Prisma 6, ShadCN/Radix, TailwindCSS 4, TypeScript 5.x strict mode).

## Input

One route path (e.g. `/reservations/[id]` or `/api/properties/:id/channels`). Optionally a specific focus area (API/frontend/cache/TS).

## Workflow

### 1. Map the Dependency Graph → `codebase-locator`

Delegate to `codebase-locator` subagent with:
- The route path (e.g. `/reservations/[id]`)
- Find the route entrypoint (`src/app/.../page.tsx` or API route handler)
- Trace the feature slice (`src/features/<slice>/...`)
- Trace to every component, hook, service, schema, mapper, constant touched
- Find test files covering the above

Return: flat list of all file paths with a short description of each.

### 2. Cross-Impact Analysis → `codebase-analyzer`

Feed file list from Step 1 to `codebase-analyzer`. For each file, find imports/usages outside the route to determine blast radius. Check dynamic imports and string-based references.

Return: per-file list of cross-references outside the route's own graph.

### 3. Apply Anti-Pattern Checklist → `antipattern-sniffer`

Feed file list + checklist below to `antipattern-sniffer`.

Return: findings grouped by file, with rule violated, severity, and line references.

### 4. Dead Code Verification (main agent)

Before claiming any code dead: grep for the symbol, check dynamic imports, string-based references (query keys, event names), and tests. Cheap enough to keep in the main agent.

### 5. Synthesize Findings Report (main agent)

Merge results from all subagents. Group by severity (Critical/High/Medium/Low). Critical/High first. Out-of-scope findings go in a "Noted for later" section. Stop and wait for approval before any edits.

### 6. Verification → `typecheck` / `test-runner`

After approved edits, delegate verification to `typecheck` and `test-runner` subagents.

## Anti-Pattern Checklist

### API / Backend
- `NextResponse.json()` in normal routes — use response builders from `@/lib/api`
- Direct `prisma.*` in routes or components — must go through service layer
- Mutation route missing `checkRateLimit(request, limiter)`
- `catch` block missing `handleApiError(error, { context })`
- Protected route missing auth wrapper
- `params`/`searchParams` used as plain objects (Next.js 15: they're Promises — must await)
- Dynamic API in a segment expected to be static (`cookies`/`headers` forces full dynamic)
- Server Action skipping auth/authz/validation
- Multiple `prisma.*` calls that could be `Promise.all`'d
- N+1: `findMany` followed by per-row `findUnique` in a loop
- Long-lived interactive transactions (>1s)
- Prisma `include` returning more relations than UI uses (prefer `select` for hot paths)

### Frontend / Client
- Direct `fetch()` in hooks — use `fetchApiData`/`mutateApi` from `@/lib/api/fetch-utils`
- `@/lib/api` barrel imported from a client component (server-only)
- Direct sonner toast — use `@/lib/logger/toast-logger`
- Plain `<Dialog>` — use `ResponsiveDialog`
- Hardcoded query keys — use `src/lib/query/query-keys.ts`
- Manual `invalidateQueries` chains — use invalidation helpers
- `toLocaleDateString` on date-only UTC — use `formatUTCDate()`
- Raw `cpropname` — use `resolvePropertyDisplayName()`
- High-impact send bypassing `usePendingSends().enqueueSend()`
- `isLoading` (v5: renamed to `isPending`)
- `cacheTime` (v4) instead of `gcTime`
- QueryClient instantiated inside a component
- Query missing `enabled` guard
- Inline object/array literals in `queryKey`
- Manual loading UI when `useSuspenseQuery` would give type-safe `data: T`

### React Patterns (Compiler + React 19)
- `useEffect` for data fetching — use `useQuery`/`useSuspenseQuery`/Server Component
- `useEffect` for derived state — compute during render or `useMemo`
- `useEffect` chains that `setState` from props
- `useEffect` for form submission — use `useActionState`
- Manual optimistic update — use `useOptimistic`
- Manual loading spinner in a form — use `useFormStatus`
- Manual `startTransition` — use `useTransition`
- Subscribing to external store via `useEffect` — use `useSyncExternalStore`
- Manual `useMemo`/`useCallback` — React Compiler handles this automatically
- `React.memo` wrapping every export — same reasoning
- `useReducer` ignored when 3+ related state vars exist

### Cache Settings (TanStack Query v5)
- `staleTime: 0` on stable reference data (statuses, types) — set 10min+
- `staleTime: Infinity` on user-mutable data — must invalidate on mutation
- `gcTime < staleTime` — data evicted while still fresh
- Live data with `refetchInterval` but also high `staleTime`
- Recommended tiers: `0` (live), `30_000` (user content), `120_000` (profile), `600_000+` (reference)

### TypeScript (5.x + Strict Mode)
- `as` casts where `satisfies` preserves narrower inference
- `any` — must be `unknown` + narrowing
- Optional `{ x?: T }` when intent is `T | undefined`
- Array/record index without undefined check
- String IDs that should be branded types
- Floating promises — missing `await` or `.catch`
- `interface` vs `type` inconsistency
- Enum-like union typed as `string` instead of literal union

### Code Quality
- Inline mappers — use `src/lib/mappers/` or `src/services/mappers/`
- Hardcoded status/rate/source values — use `src/lib/constants/`
- Schemas duplicated across features — consolidate
- Tests asserting implementation details, not behavior
- Comments explaining WHAT instead of WHY

## Findings Report Format

```
### [Critical|High|Medium|Low] <title>
File: path/to/file.tsx:42-58
Issue: <one sentence>
Why it matters: <bug | perf | security | maintainability | DX>
Cross-impact: <affected files>
Fix: <surgical proposed change>
Verification: <test name, grep result, or type check>
```

Severity: Critical (bug/security/data integrity), High (future bugs), Medium (best-practice drift), Low (dead code/cleanup).

## Rules

- Investigation-only until user approves findings. No edits.
- One route per pass. No "while we're at it" cleanup.
- No commits or pushes without explicit approval.
- Do NOT recommend wholesale Server Actions migration — this repo uses Route Handlers + service layer.
- Before recommending React Compiler memo removal: confirm compiler is enabled in `next.config`.
