#!/usr/bin/env sh

set -eu

STATE_FILE="${OPENCODE_CODEX_ONLY_STATE:-$HOME/.config/opencode/codex-only.env}"

FREE_FAST_MODEL="${OPENCODE_FREE_FAST_MODEL:-opencode/deepseek-v4-flash-free}"

# GPT-5.6 Codex tier defaults. These are the only models used when codex-only is ON.
SOL_MODEL="${OPENCODE_SOL_MODEL:-openai/gpt-5.6-sol}"
TERRA_MODEL="${OPENCODE_TERRA_MODEL:-openai/gpt-5.6-terra}"
LUNA_FAST_MODEL="${OPENCODE_LUNA_FAST_MODEL:-openai/gpt-5.6-luna-fast}"

# Non-Codex defaults used when codex-only is OFF. Preserve every existing assignment.
DEFAULT_ORCHESTRATOR_MODEL="${OPENCODE_DEFAULT_ORCHESTRATOR_MODEL:-$SOL_MODEL}"
DEFAULT_LOCATOR_MODEL="${OPENCODE_DEFAULT_LOCATOR_MODEL:-opencode-go/deepseek-v4-flash}"
DEFAULT_ANALYZER_MODEL="${OPENCODE_DEFAULT_ANALYZER_MODEL:-opencode-go/qwen3.7-max}"
DEFAULT_CONTEXT_MODEL="${OPENCODE_DEFAULT_CONTEXT_MODEL:-opencode-go/glm-5.2}"
DEFAULT_SNIFFER_MODEL="${OPENCODE_DEFAULT_SNIFFER_MODEL:-opencode-go/mimo-v2.5-pro}"
DEFAULT_FRONTEND_MODEL="${OPENCODE_DEFAULT_FRONTEND_MODEL:-opencode-go/kimi-k2.7-code}"
DEFAULT_MOBILE_MODEL="${OPENCODE_DEFAULT_MOBILE_MODEL:-opencode-go/kimi-k2.6}"
DEFAULT_BACKEND_MODEL="${OPENCODE_DEFAULT_BACKEND_MODEL:-opencode-go/qwen3.7-max}"
DEFAULT_CLOUD_MODEL="${OPENCODE_DEFAULT_CLOUD_MODEL:-opencode-go/glm-5.2}"
DEFAULT_DB_MODEL="${OPENCODE_DEFAULT_DB_MODEL:-opencode-go/qwen3.7-max}"
DEFAULT_DEPLOY_MODEL="${OPENCODE_DEFAULT_DEPLOY_MODEL:-opencode-go/kimi-k2.7-code}"
DEFAULT_DEVOPS_MODEL="${OPENCODE_DEFAULT_DEVOPS_MODEL:-opencode-go/glm-5.1}"
DEFAULT_PERF_MODEL="${OPENCODE_DEFAULT_PERF_MODEL:-opencode-go/minimax-m3}"
DEFAULT_TEST_MODEL="${OPENCODE_DEFAULT_TEST_MODEL:-opencode-go/qwen3.7-plus}"
DEFAULT_EXECUTOR_MODEL="${OPENCODE_DEFAULT_EXECUTOR_MODEL:-opencode-go/kimi-k2.7-code}"

# Built-in agents that previously had no explicit default inherit from the closest analogue.
DEFAULT_GENERAL_MODEL="${OPENCODE_DEFAULT_GENERAL_MODEL:-$DEFAULT_ANALYZER_MODEL}"
DEFAULT_EXPLORE_MODEL="${OPENCODE_DEFAULT_EXPLORE_MODEL:-$DEFAULT_LOCATOR_MODEL}"
DEFAULT_RESPONSE_REVIEWER_MODEL="${OPENCODE_DEFAULT_RESPONSE_REVIEWER_MODEL:-$DEFAULT_ANALYZER_MODEL}"
DEFAULT_SPEC_REVIEWER_MODEL="${OPENCODE_DEFAULT_SPEC_REVIEWER_MODEL:-$DEFAULT_ANALYZER_MODEL}"

write_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf 'export OPENCODE_CODEX_ONLY=%s\n' "$1" > "$STATE_FILE"
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
  OPENCODE_CODEX_ONLY="${OPENCODE_CODEX_ONLY:-0}"
}

print_exports() {
  load_state

  printf 'export OPENCODE_ORCHESTRATOR_MODEL=%s\n' "$DEFAULT_ORCHESTRATOR_MODEL"

  if [ "$OPENCODE_CODEX_ONLY" = "1" ]; then
    printf 'export OPENCODE_FAST_MODEL=%s\n' "$LUNA_FAST_MODEL"
    printf 'export OPENCODE_MAX_CONCURRENT=10\n'

    printf 'export OPENCODE_LOCATOR_MODEL=%s\n' "$LUNA_FAST_MODEL"
    printf 'export OPENCODE_GENERAL_MODEL=%s\n' "$TERRA_MODEL"
    printf 'export OPENCODE_ANALYZER_MODEL=%s\n' "$TERRA_MODEL"
    printf 'export OPENCODE_CONTEXT_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_SNIFFER_MODEL=%s\n' "$TERRA_MODEL"
    printf 'export OPENCODE_FRONTEND_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_MOBILE_MODEL=%s\n' "$TERRA_MODEL"
    printf 'export OPENCODE_BACKEND_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_CLOUD_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_DB_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_DEPLOY_MODEL=%s\n' "$TERRA_MODEL"
    printf 'export OPENCODE_DEVOPS_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_PERF_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_TEST_AUTOMATOR_MODEL=%s\n' "$TERRA_MODEL"
    printf 'export OPENCODE_EXECUTOR_MODEL=%s\n' "$SOL_MODEL"
    printf 'export OPENCODE_EXPLORE_MODEL=%s\n' "$LUNA_FAST_MODEL"
    printf 'export OPENCODE_RESPONSE_REVIEWER_MODEL=%s\n' "$TERRA_MODEL"
    printf 'export OPENCODE_SPEC_REVIEWER_MODEL=%s\n' "$TERRA_MODEL"

    printf 'export OPENCODE_ORCHESTRATOR_VARIANT=%s\n' "high"
    printf 'export OPENCODE_LOCATOR_VARIANT=%s\n' "low"
    printf 'export OPENCODE_GENERAL_VARIANT=%s\n' "medium"
    printf 'export OPENCODE_ANALYZER_VARIANT=%s\n' "medium"
    printf 'export OPENCODE_CONTEXT_VARIANT=%s\n' "high"
    printf 'export OPENCODE_SNIFFER_VARIANT=%s\n' "medium"
    printf 'export OPENCODE_FRONTEND_VARIANT=%s\n' "high"
    printf 'export OPENCODE_MOBILE_VARIANT=%s\n' "high"
    printf 'export OPENCODE_BACKEND_VARIANT=%s\n' "high"
    printf 'export OPENCODE_CLOUD_VARIANT=%s\n' "high"
    printf 'export OPENCODE_DB_VARIANT=%s\n' "high"
    printf 'export OPENCODE_DEPLOY_VARIANT=%s\n' "high"
    printf 'export OPENCODE_DEVOPS_VARIANT=%s\n' "high"
    printf 'export OPENCODE_PERF_VARIANT=%s\n' "high"
    printf 'export OPENCODE_TEST_AUTOMATOR_VARIANT=%s\n' "high"
    printf 'export OPENCODE_EXECUTOR_VARIANT=%s\n' "high"
    printf 'export OPENCODE_EXPLORE_VARIANT=%s\n' "low"
    printf 'export OPENCODE_RESPONSE_REVIEWER_VARIANT=%s\n' "medium"
    printf 'export OPENCODE_SPEC_REVIEWER_VARIANT=%s\n' "high"
    printf 'export OPENCODE_FAST_VARIANT=%s\n' "none"
  else
    printf 'export OPENCODE_FAST_MODEL=%s\n' "$FREE_FAST_MODEL"
    printf 'export OPENCODE_MAX_CONCURRENT=2\n'

    printf 'export OPENCODE_LOCATOR_MODEL=%s\n' "$DEFAULT_LOCATOR_MODEL"
    printf 'export OPENCODE_GENERAL_MODEL=%s\n' "$DEFAULT_GENERAL_MODEL"
    printf 'export OPENCODE_ANALYZER_MODEL=%s\n' "$DEFAULT_ANALYZER_MODEL"
    printf 'export OPENCODE_CONTEXT_MODEL=%s\n' "$DEFAULT_CONTEXT_MODEL"
    printf 'export OPENCODE_SNIFFER_MODEL=%s\n' "$DEFAULT_SNIFFER_MODEL"
    printf 'export OPENCODE_FRONTEND_MODEL=%s\n' "$DEFAULT_FRONTEND_MODEL"
    printf 'export OPENCODE_MOBILE_MODEL=%s\n' "$DEFAULT_MOBILE_MODEL"
    printf 'export OPENCODE_BACKEND_MODEL=%s\n' "$DEFAULT_BACKEND_MODEL"
    printf 'export OPENCODE_CLOUD_MODEL=%s\n' "$DEFAULT_CLOUD_MODEL"
    printf 'export OPENCODE_DB_MODEL=%s\n' "$DEFAULT_DB_MODEL"
    printf 'export OPENCODE_DEPLOY_MODEL=%s\n' "$DEFAULT_DEPLOY_MODEL"
    printf 'export OPENCODE_DEVOPS_MODEL=%s\n' "$DEFAULT_DEVOPS_MODEL"
    printf 'export OPENCODE_PERF_MODEL=%s\n' "$DEFAULT_PERF_MODEL"
    printf 'export OPENCODE_TEST_AUTOMATOR_MODEL=%s\n' "$DEFAULT_TEST_MODEL"
    printf 'export OPENCODE_EXECUTOR_MODEL=%s\n' "$DEFAULT_EXECUTOR_MODEL"
    printf 'export OPENCODE_EXPLORE_MODEL=%s\n' "$DEFAULT_EXPLORE_MODEL"
    printf 'export OPENCODE_RESPONSE_REVIEWER_MODEL=%s\n' "$DEFAULT_RESPONSE_REVIEWER_MODEL"
    printf 'export OPENCODE_SPEC_REVIEWER_MODEL=%s\n' "$DEFAULT_SPEC_REVIEWER_MODEL"

    # Empty variants let non-Codex providers keep their own default reasoning effort.
    printf 'export OPENCODE_ORCHESTRATOR_VARIANT=%s\n' ""
    printf 'export OPENCODE_LOCATOR_VARIANT=%s\n' ""
    printf 'export OPENCODE_GENERAL_VARIANT=%s\n' ""
    printf 'export OPENCODE_ANALYZER_VARIANT=%s\n' ""
    printf 'export OPENCODE_CONTEXT_VARIANT=%s\n' ""
    printf 'export OPENCODE_SNIFFER_VARIANT=%s\n' ""
    printf 'export OPENCODE_FRONTEND_VARIANT=%s\n' ""
    printf 'export OPENCODE_MOBILE_VARIANT=%s\n' ""
    printf 'export OPENCODE_BACKEND_VARIANT=%s\n' ""
    printf 'export OPENCODE_CLOUD_VARIANT=%s\n' ""
    printf 'export OPENCODE_DB_VARIANT=%s\n' ""
    printf 'export OPENCODE_DEPLOY_VARIANT=%s\n' ""
    printf 'export OPENCODE_DEVOPS_VARIANT=%s\n' ""
    printf 'export OPENCODE_PERF_VARIANT=%s\n' ""
    printf 'export OPENCODE_TEST_AUTOMATOR_VARIANT=%s\n' ""
    printf 'export OPENCODE_EXECUTOR_VARIANT=%s\n' ""
    printf 'export OPENCODE_EXPLORE_VARIANT=%s\n' ""
    printf 'export OPENCODE_RESPONSE_REVIEWER_VARIANT=%s\n' ""
    printf 'export OPENCODE_SPEC_REVIEWER_VARIANT=%s\n' ""
    printf 'export OPENCODE_FAST_VARIANT=%s\n' ""
  fi
}

status() {
  load_state
  printf 'OPENCODE_CODEX_ONLY=%s\n' "$OPENCODE_CODEX_ONLY"
  print_exports | sed 's/^export //'
}

case "${1:-status}" in
  on|enable|enabled|1|true)
    write_state 1
    printf 'codex-only enabled. Restart OpenCode for model assignments to reload.\n'
    ;;
  off|disable|disabled|0|false)
    write_state 0
    printf 'codex-only disabled. Restart OpenCode for model assignments to reload.\n'
    ;;
  exports)
    print_exports
    ;;
  status)
    status
    ;;
  *)
    printf 'Usage: %s [on|off|status|exports]\n' "$0" >&2
    exit 2
    ;;
esac
