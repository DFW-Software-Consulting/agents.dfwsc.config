import type { Plugin } from "@opencode-ai/plugin"

// opencode-free mode: when OPENCODE_FREE=1, swap every subagent
// (mode: subagent, excluding opencode's hidden internal plumbing agents)
// to a free model. Toggle via the `oc-free` shell command; change the model
// with OPENCODE_FREE_MODEL (defaults to opencode-go/minimax-m3.1-flash-free).

// In the mixed launcher profile subagents may only use OpenCode Go or Claude, so a
// free model from any other provider is refused and free mode stays off.

const EXCLUDED_AGENT_NAMES = new Set(["compaction", "title", "summary"])
const MIXED_ALLOWED_MODEL = /^(opencode-go|claude-agent)\/[^/#]+/

export const FreeModePlugin: Plugin = async () => {
  const isEnabled = (process.env.OPENCODE_FREE === "1")

  if (isEnabled) {
    const freeModel = process.env.OPENCODE_FREE_MODEL || "opencode-go/minimax-m3.1-flash-free"
    const isMixed = process.env.OPENCODE_MODEL_PROFILE === "mixed" || process.env.OPENCODE_DEFAULT_AGENT === "orchestrator-mixed"
    if (isMixed && !MIXED_ALLOWED_MODEL.test(freeModel)) {
      console.error(`[free-mode] OPENCODE_FREE_MODEL must use opencode-go/* or claude-agent/* in the mixed profile (got ${freeModel}); free mode disabled`)
      return {}
    }

    return {
      config: (cfg) => {
        cfg.small_model = freeModel

        const agents = cfg.agent as Record<string, { mode?: string; model?: string; variant?: string }> | undefined
        if (!agents) return

        for (const [name, agent] of Object.entries(agents)) {
          if (!agent || agent.mode !== "subagent") continue
          if (EXCLUDED_AGENT_NAMES.has(name)) continue
          agent.model = freeModel
          if ("variant" in agent) delete agent.variant
        }
      },
    }
  }

  return {}
}

export default FreeModePlugin
