#!/usr/bin/env sh

set -eu

STATE_FILE="${OPENCODE_CODEX_ONLY_STATE:-$HOME/.config/opencode/codex-only.env}"

FREE_FAST_MODEL="${OPENCODE_FREE_FAST_MODEL:-opencode/deepseek-v4-flash-free}"
DEFAULT_ORCHESTRATOR_MODEL="${OPENCODE_DEFAULT_ORCHESTRATOR_MODEL:-openai/gpt-5}"
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

CODEX_MODEL="${OPENCODE_CODEX_MODEL:-openai/gpt-5.5}"
CODEX_SMALL_MODEL="${OPENCODE_CODEX_SMALL_MODEL:-openai/gpt-5.5-fast}"

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

  # Always keep free-model agents on the free fast model.
  printf 'export OPENCODE_FAST_MODEL=%s\n' "$FREE_FAST_MODEL"
  printf 'export OPENCODE_ORCHESTRATOR_MODEL=%s\n' "$DEFAULT_ORCHESTRATOR_MODEL"

  if [ "$OPENCODE_CODEX_ONLY" = "1" ]; then
    printf 'export OPENCODE_MAX_CONCURRENT=10\n'
    printf 'export OPENCODE_LOCATOR_MODEL=%s\n' "$CODEX_SMALL_MODEL"
    printf 'export OPENCODE_ANALYZER_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_CONTEXT_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_SNIFFER_MODEL=%s\n' "$CODEX_SMALL_MODEL"
    printf 'export OPENCODE_FRONTEND_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_MOBILE_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_BACKEND_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_CLOUD_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_DB_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_DEPLOY_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_DEVOPS_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_PERF_MODEL=%s\n' "$CODEX_MODEL"
    printf 'export OPENCODE_TEST_MODEL=%s\n' "$CODEX_SMALL_MODEL"
    printf 'export OPENCODE_EXECUTOR_MODEL=%s\n' "$CODEX_MODEL"
  else
    printf 'export OPENCODE_MAX_CONCURRENT=2\n'
    printf 'export OPENCODE_LOCATOR_MODEL=%s\n' "$DEFAULT_LOCATOR_MODEL"
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
    printf 'export OPENCODE_TEST_MODEL=%s\n' "$DEFAULT_TEST_MODEL"
    printf 'export OPENCODE_EXECUTOR_MODEL=%s\n' "$DEFAULT_EXECUTOR_MODEL"
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
