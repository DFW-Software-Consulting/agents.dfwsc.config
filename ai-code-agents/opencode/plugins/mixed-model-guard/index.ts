// Mixed-profile model guard: when the `opencode` launcher runs the mixed profile,
// every subagent must run on OpenCode Go or Claude. The conversational primary
// model (which may be OpenAI) is left alone.
//
// Two layers, the second a backstop for the first:
// 1. Subagent tool: a per-call `model` override outside the allowlist is dropped.
//    If the target agent's resolved model is then missing or outside the
//    allowlist (it would inherit the primary), the call is pinned to a safe
//    allowed model instead.
// 2. Model requests: a request from a child session or subagent that still
//    targets a disallowed provider is sent to an unroutable address and never
//    retried, so it fails closed instead of reaching that provider.
//
// Written against the OpenCode V2 plugin API without importing @opencode/plugin,
// so it loads from this directory with no install step.

type ModelRef = { providerID: string; id: string; variant?: string }
type AgentInfo = { id: string; mode?: string; model?: ModelRef | null }

const ALLOWED_PROVIDERS = new Set(["opencode-go", "claude-agent"])
const DEFAULT_SUBAGENT_MODEL = "claude-agent/sonnet"
const BLOCKED_BASE_URL = "http://127.0.0.1:9/mixed-model-guard-blocked"
const SUBAGENT_TOOLS = new Set(["subagent", "task"])

export const isMixedProfile = (env: Record<string, string | undefined> = process.env) =>
  env.OPENCODE_MODEL_PROFILE === "mixed" || env.OPENCODE_DEFAULT_AGENT === "orchestrator-mixed"

export const isAllowedProvider = (providerID: unknown) =>
  typeof providerID === "string" && ALLOWED_PROVIDERS.has(providerID)

// Subagent model overrides are written "providerID/modelID" or "providerID/modelID#variant".
export const isAllowedModel = (value: unknown) => {
  if (typeof value !== "string") return false
  const ref = value.split("#", 1)[0]
  const slash = ref.indexOf("/")
  return slash > 0 && slash < ref.length - 1 && isAllowedProvider(ref.slice(0, slash))
}

export const safeDefaultModel = (env: Record<string, string | undefined> = process.env) =>
  isAllowedModel(env.OPENCODE_GENERAL_MODEL) ? (env.OPENCODE_GENERAL_MODEL as string) : DEFAULT_SUBAGENT_MODEL

const unwrap = <T>(value: unknown): T | undefined =>
  (value && typeof value === "object" && "data" in value ? (value as { data: T }).data : value) as T | undefined

export async function setup(ctx: any) {
  if (!isMixedProfile()) return

  const fallback = safeDefaultModel()
  const blockedSessions = new Set<string>()
  const subagentSessions = new Map<string, Promise<boolean>>()

  const agentInfo = async (agentID: string) => {
    try {
      return unwrap<AgentInfo>(await ctx.agent.get({ agentID }))
    } catch (error) {
      console.warn(`[mixed-model-guard] agent lookup failed for ${agentID}: ${String(error)}`)
      return undefined
    }
  }

  await ctx.tool.hook("execute.before", async (event: { tool: string; input: unknown }) => {
    if (!SUBAGENT_TOOLS.has(event.tool)) return
    const input = event.input as Record<string, unknown> | undefined
    if (!input) return

    const { model: override, ...rest } = input
    if (override !== undefined && override !== "") {
      if (isAllowedModel(override)) return
      console.warn(`[mixed-model-guard] dropped subagent model override ${String(override)}`)
    }

    const agentID = typeof rest.agent === "string" ? rest.agent : rest.subagent_type
    if (typeof agentID !== "string" || agentID === "") {
      // Continuing an existing child session; layer 2 still guards its requests.
      event.input = rest
      return
    }

    const configured = (await agentInfo(agentID))?.model
    if (configured && isAllowedProvider(configured.providerID)) {
      event.input = rest
      return
    }

    console.warn(
      `[mixed-model-guard] subagent ${agentID} resolves to ${configured ? `${configured.providerID}/${configured.id}` : "the primary model"}; pinned to ${fallback}`,
    )
    event.input = { ...rest, model: fallback }
  })

  // A session counts as a subagent run when it has a parent session or runs a
  // non-primary agent. If neither can be determined, treat it as a subagent.
  const isSubagentSession = (sessionID: string, agentID: string) => {
    const key = `${sessionID}:${agentID}`
    let result = subagentSessions.get(key)
    if (!result) {
      result = (async () => {
        try {
          const session = unwrap<{ parentID?: string }>(await ctx.session.get({ sessionID }))
          if (session?.parentID) return true
        } catch (error) {
          console.warn(`[mixed-model-guard] session lookup failed for ${sessionID}: ${String(error)}`)
        }
        const agent = await agentInfo(agentID)
        return agent?.mode ? agent.mode !== "primary" : true
      })()
      subagentSessions.set(key, result)
    }
    return result
  }

  await ctx.session.hook(
    "model.request",
    async (event: { sessionID: string; agent: string; model: ModelRef; baseURL?: string; headers: Record<string, string> }) => {
      if (isAllowedProvider(event.model.providerID)) return
      if (!(await isSubagentSession(event.sessionID, event.agent))) return
      blockedSessions.add(event.sessionID)
      console.error(
        `[mixed-model-guard] blocked ${event.model.providerID}/${event.model.id} for subagent ${event.agent} in session ${event.sessionID}`,
      )
      event.baseURL = BLOCKED_BASE_URL
      event.headers = {}
    },
  )

  await ctx.session.hook("retry", (event: { sessionID: string; model: ModelRef; decision: unknown }) => {
    if (blockedSessions.has(event.sessionID) && !isAllowedProvider(event.model.providerID)) {
      event.decision = { retry: false }
    }
  })
}

export default { id: "dfwsc.mixed-model-guard", setup }
