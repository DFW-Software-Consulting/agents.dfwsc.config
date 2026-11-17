#!/usr/bin/env sh

set -eu

profile_from_command() {
  case "${0##*/}" in
    opencode-codex) printf '%s\n' codex ;;
    opencode-go) printf '%s\n' go ;;
    opencode-claude) printf '%s\n' claude ;;
    *)
      if [ "$#" -eq 0 ]; then
        return 1
      fi
      printf '%s\n' "$1"
      ;;
  esac
}

PROFILE="$(profile_from_command "$@")" || {
  printf 'Usage: %s <mixed|codex|go|claude> [opencode arguments]\n' "${0##*/}" >&2
  exit 2
}

case "${0##*/}" in
  model-profile.sh)
    shift
    ;;
esac

set_variants() {
  OPENCODE_PRIMARY_VARIANT="$1"
  OPENCODE_PLAN_VARIANT="$2"
  OPENCODE_FAST_VARIANT="$3"
  OPENCODE_LOCATOR_VARIANT="$3"
  OPENCODE_EXPLORE_VARIANT="$3"
  OPENCODE_GENERAL_VARIANT="$4"
  OPENCODE_ANALYZER_VARIANT="$4"
  OPENCODE_CONTEXT_VARIANT="$4"
  OPENCODE_SNIFFER_VARIANT="$4"
  OPENCODE_FRONTEND_VARIANT="$4"
  OPENCODE_MOBILE_VARIANT="$4"
  OPENCODE_BACKEND_VARIANT="$4"
  OPENCODE_CLOUD_VARIANT="$4"
  OPENCODE_DB_VARIANT="$4"
  OPENCODE_DEPLOY_VARIANT="$4"
  OPENCODE_DEVOPS_VARIANT="$4"
  OPENCODE_PERF_VARIANT="$4"
  OPENCODE_TEST_AUTOMATOR_VARIANT="$4"
  OPENCODE_EXECUTOR_VARIANT="$4"
  OPENCODE_SPEC_REVIEWER_VARIANT="$4"
}

mixed_subagent_model() {
  variable_name="$1"
  configured_value="$2"
  fallback="$3"
  value="${configured_value:-$fallback}"

  case "$value" in
    opencode-go/*|claude-agent/*)
      printf '%s\n' "$value"
      ;;
    *)
      printf '%s must use opencode-go/* or claude-agent/* in the mixed profile (got %s)\n' \
        "$variable_name" "$value" >&2
      exit 2
      ;;
  esac
}

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 { sub("^" key ":[ \t]*", ""); sub("[ \t]+$", ""); print; exit }
  ' "$1"
}

# Every subagent must resolve to an allowed model; an empty binding would inherit the
# conversational primary model.
check_mixed_subagent_bindings() {
  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required to validate mixed-profile subagent models\n' >&2
    exit 2
  }

  subagents="$(
    for agent_file in "$CONFIG_DIR"/agents/*.md; do
      if [ "$(frontmatter_value "$agent_file" mode)" = subagent ]; then
        agent_name="${agent_file##*/}"
        printf '%s\n' "${agent_name%.md}"
      fi
    done
    jq -r '.agent // {} | to_entries[] | select(.value.mode == "subagent") | .key' \
      "$CONFIG_DIR/global.opencode.json" "$CONFIG_DIR/opencode.json"
  )"
  invalid=0

  for agent_name in $(printf '%s\n' "$subagents" | LC_ALL=C sort -u); do
    if [ -f "$CONFIG_DIR/agents/$agent_name.md" ]; then
      binding="$(frontmatter_value "$CONFIG_DIR/agents/$agent_name.md" model)"
      if [ -n "$binding" ] && ! is_mixed_subagent_model "$binding"; then
        printf 'Subagent %s uses %s in agents/%s.md; mixed subagents must use opencode-go/* or claude-agent/*\n' \
          "$agent_name" "$binding" "$agent_name" >&2
        invalid=1
      fi
    fi

    for config_file in global.opencode.json opencode.json; do
      binding="$(jq -r --arg name "$agent_name" '.agent[$name].model // empty' "$CONFIG_DIR/$config_file")"
      case "$binding" in
        '{env:'*'}')
          variable_name="${binding#\{env:}"
          variable_name="${variable_name%\}}"
          resolved="$(printenv "$variable_name" || true)"
          ;;
        *)
          variable_name=''
          resolved="$binding"
          ;;
      esac

      if ! is_mixed_subagent_model "$resolved"; then
        printf 'Subagent %s has no allowed model binding in %s (%s%s); mixed subagents must use opencode-go/* or claude-agent/*\n' \
          "$agent_name" "$config_file" "${variable_name:+$variable_name=}" "${resolved:-unset}" >&2
        invalid=1
      fi
    done
  done

  if [ "$invalid" -ne 0 ]; then
    exit 2
  fi
}

is_mixed_subagent_model() {
  case "$1" in
    opencode-go/?*|claude-agent/?*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$PROFILE" in
  mixed)
    # Keep the conversational model independent; every delegated worker is Go or Claude.
    OPENCODE_DEFAULT_AGENT="orchestrator-mixed"
    OPENCODE_PRIMARY_MODEL="${OPENCODE_MIXED_PRIMARY_MODEL:-openai/gpt-5.6-sol}"
    OPENCODE_PRIMARY_VARIANT="medium"
    OPENCODE_PLAN_MODEL="${OPENCODE_MIXED_PLAN_MODEL:-claude-agent/opus}"
    OPENCODE_PLAN_VARIANT=""
    OPENCODE_SMALL_MODEL="$(mixed_subagent_model OPENCODE_MIXED_FAST_MODEL "${OPENCODE_MIXED_FAST_MODEL:-}" opencode-go/glm-5.3-flash)"
    OPENCODE_FAST_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_FAST_VARIANT=""
    OPENCODE_LOCATOR_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_LOCATOR_VARIANT=""
    OPENCODE_EXPLORE_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_EXPLORE_VARIANT=""
    OPENCODE_GENERAL_MODEL="$(mixed_subagent_model OPENCODE_MIXED_BALANCED_MODEL "${OPENCODE_MIXED_BALANCED_MODEL:-}" claude-agent/sonnet)"
    OPENCODE_GENERAL_VARIANT=""
    OPENCODE_ANALYZER_MODEL="$(mixed_subagent_model OPENCODE_MIXED_ANALYZER_MODEL "${OPENCODE_MIXED_ANALYZER_MODEL:-}" opencode-go/glm-5.2)"
    OPENCODE_ANALYZER_VARIANT=""
    OPENCODE_CONTEXT_MODEL="$(mixed_subagent_model OPENCODE_MIXED_CONTEXT_MODEL "${OPENCODE_MIXED_CONTEXT_MODEL:-}" claude-agent/opus)"
    OPENCODE_CONTEXT_VARIANT=""
    OPENCODE_SNIFFER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_SNIFFER_VARIANT=""
    OPENCODE_FRONTEND_MODEL="$(mixed_subagent_model OPENCODE_MIXED_FRONTEND_MODEL "${OPENCODE_MIXED_FRONTEND_MODEL:-}" claude-agent/opus)"
    OPENCODE_FRONTEND_VARIANT=""
    OPENCODE_MOBILE_MODEL="$OPENCODE_ANALYZER_MODEL"
    OPENCODE_MOBILE_VARIANT=""
    OPENCODE_BACKEND_MODEL="$(mixed_subagent_model OPENCODE_MIXED_FLAGSHIP_MODEL "${OPENCODE_MIXED_FLAGSHIP_MODEL:-}" opencode-go/qwen3.8-max)"
    OPENCODE_BACKEND_VARIANT=""
    OPENCODE_CLOUD_MODEL="$OPENCODE_CONTEXT_MODEL"
    OPENCODE_CLOUD_VARIANT=""
    OPENCODE_DB_MODEL="$OPENCODE_BACKEND_MODEL"
    OPENCODE_DB_VARIANT=""
    OPENCODE_DEPLOY_MODEL="$(mixed_subagent_model OPENCODE_MIXED_DEPLOY_MODEL "${OPENCODE_MIXED_DEPLOY_MODEL:-}" opencode-go/kimi-k2.7-code)"
    OPENCODE_DEPLOY_VARIANT=""
    OPENCODE_DEVOPS_MODEL="$OPENCODE_BACKEND_MODEL"
    OPENCODE_DEVOPS_VARIANT=""
    OPENCODE_PERF_MODEL="$(mixed_subagent_model OPENCODE_MIXED_PERF_MODEL "${OPENCODE_MIXED_PERF_MODEL:-}" opencode-go/minimax-m3)"
    OPENCODE_PERF_VARIANT=""
    OPENCODE_TEST_AUTOMATOR_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_TEST_AUTOMATOR_VARIANT=""
    OPENCODE_EXECUTOR_MODEL="$OPENCODE_BACKEND_MODEL"
    OPENCODE_EXECUTOR_VARIANT=""
    OPENCODE_SPEC_REVIEWER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_SPEC_REVIEWER_VARIANT=""
    OPENCODE_MAX_CONCURRENT="${OPENCODE_MIXED_MAX_CONCURRENT:-6}"
    if [ "${OPENCODE_FREE:-}" = "1" ] && [ -n "${OPENCODE_FREE_MODEL:-}" ]; then
      OPENCODE_FREE_MODEL="$(mixed_subagent_model OPENCODE_FREE_MODEL "$OPENCODE_FREE_MODEL" '')"
    fi
    ;;
  codex)
    OPENCODE_DEFAULT_AGENT="orchestrator"
    OPENCODE_PRIMARY_MODEL="${OPENCODE_CODEX_PRIMARY_MODEL:-openai/gpt-5.6-sol}"
    OPENCODE_PLAN_MODEL="${OPENCODE_CODEX_PLAN_MODEL:-openai/gpt-5.6-sol}"
    OPENCODE_SMALL_MODEL="${OPENCODE_CODEX_SMALL_MODEL:-openai/gpt-5.6-luna}"
    OPENCODE_FAST_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_LOCATOR_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_EXPLORE_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_GENERAL_MODEL="${OPENCODE_CODEX_BALANCED_MODEL:-openai/gpt-5.6-terra}"
    OPENCODE_ANALYZER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_SNIFFER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_MOBILE_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_DEPLOY_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_TEST_AUTOMATOR_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_SPEC_REVIEWER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_CONTEXT_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_FRONTEND_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_BACKEND_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_CLOUD_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_DB_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_DEVOPS_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_PERF_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_EXECUTOR_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_MAX_CONCURRENT="${OPENCODE_CODEX_MAX_CONCURRENT:-10}"
    set_variants medium high low medium
    ;;
  go|opencode-go)
    PROFILE=go
    OPENCODE_DEFAULT_AGENT="orchestrator"
    OPENCODE_PRIMARY_MODEL="${OPENCODE_GO_PRIMARY_MODEL:-opencode-go/qwen3.8-max}"
    OPENCODE_PLAN_MODEL="${OPENCODE_GO_PLAN_MODEL:-opencode-go/qwen3.8-max}"
    OPENCODE_SMALL_MODEL="${OPENCODE_GO_FAST_MODEL:-opencode-go/glm-5.3-flash}"
    OPENCODE_FAST_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_LOCATOR_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_EXPLORE_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_GENERAL_MODEL="${OPENCODE_GO_GENERAL_MODEL:-opencode-go/mimo-v2.5-pro}"
    OPENCODE_ANALYZER_MODEL="${OPENCODE_GO_ANALYZER_MODEL:-opencode-go/glm-5.2}"
    OPENCODE_CONTEXT_MODEL="${OPENCODE_GO_CONTEXT_MODEL:-opencode-go/glm-5.3}"
    OPENCODE_SNIFFER_MODEL="$OPENCODE_ANALYZER_MODEL"
    OPENCODE_FRONTEND_MODEL="${OPENCODE_GO_CODING_MODEL:-opencode-go/kimi-k2.7-code}"
    OPENCODE_MOBILE_MODEL="$OPENCODE_ANALYZER_MODEL"
    OPENCODE_BACKEND_MODEL="$OPENCODE_PLAN_MODEL"
    OPENCODE_CLOUD_MODEL="$OPENCODE_CONTEXT_MODEL"
    OPENCODE_DB_MODEL="$OPENCODE_PLAN_MODEL"
    OPENCODE_DEPLOY_MODEL="$OPENCODE_FRONTEND_MODEL"
    OPENCODE_DEVOPS_MODEL="$OPENCODE_CONTEXT_MODEL"
    OPENCODE_PERF_MODEL="${OPENCODE_GO_PERF_MODEL:-opencode-go/minimax-m3}"
    OPENCODE_TEST_AUTOMATOR_MODEL="$OPENCODE_ANALYZER_MODEL"
    OPENCODE_EXECUTOR_MODEL="$OPENCODE_FRONTEND_MODEL"
    OPENCODE_SPEC_REVIEWER_MODEL="$OPENCODE_PLAN_MODEL"
    OPENCODE_MAX_CONCURRENT="${OPENCODE_GO_MAX_CONCURRENT:-4}"
    set_variants '' '' '' ''
    ;;
  claude)
    OPENCODE_DEFAULT_AGENT="orchestrator"
    OPENCODE_PRIMARY_MODEL="${OPENCODE_CLAUDE_PRIMARY_MODEL:-claude-agent/opus}"
    OPENCODE_PLAN_MODEL="${OPENCODE_CLAUDE_PLAN_MODEL:-claude-agent/opus}"
    OPENCODE_SMALL_MODEL="${OPENCODE_CLAUDE_FAST_MODEL:-claude-agent/haiku}"
    OPENCODE_FAST_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_LOCATOR_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_EXPLORE_MODEL="$OPENCODE_SMALL_MODEL"
    OPENCODE_GENERAL_MODEL="${OPENCODE_CLAUDE_BALANCED_MODEL:-claude-agent/sonnet}"
    OPENCODE_ANALYZER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_CONTEXT_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_SNIFFER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_FRONTEND_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_MOBILE_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_BACKEND_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_CLOUD_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_DB_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_DEPLOY_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_DEVOPS_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_PERF_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_TEST_AUTOMATOR_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_EXECUTOR_MODEL="$OPENCODE_PRIMARY_MODEL"
    OPENCODE_SPEC_REVIEWER_MODEL="$OPENCODE_GENERAL_MODEL"
    OPENCODE_MAX_CONCURRENT="${OPENCODE_CLAUDE_MAX_CONCURRENT:-4}"
    set_variants '' '' '' ''
    ;;
  *)
    printf 'Unknown OpenCode model profile: %s\n' "$PROFILE" >&2
    exit 2
    ;;
esac

OPENCODE_MODEL_PROFILE="$PROFILE"

export OPENCODE_MODEL_PROFILE
export OPENCODE_PRIMARY_MODEL OPENCODE_PRIMARY_VARIANT
export OPENCODE_DEFAULT_AGENT
export OPENCODE_PLAN_MODEL OPENCODE_PLAN_VARIANT OPENCODE_SMALL_MODEL
export OPENCODE_FAST_MODEL OPENCODE_FAST_VARIANT OPENCODE_MAX_CONCURRENT
export OPENCODE_LOCATOR_MODEL OPENCODE_LOCATOR_VARIANT
export OPENCODE_GENERAL_MODEL OPENCODE_GENERAL_VARIANT
export OPENCODE_ANALYZER_MODEL OPENCODE_ANALYZER_VARIANT
export OPENCODE_CONTEXT_MODEL OPENCODE_CONTEXT_VARIANT
export OPENCODE_SNIFFER_MODEL OPENCODE_SNIFFER_VARIANT
export OPENCODE_FRONTEND_MODEL OPENCODE_FRONTEND_VARIANT
export OPENCODE_MOBILE_MODEL OPENCODE_MOBILE_VARIANT
export OPENCODE_BACKEND_MODEL OPENCODE_BACKEND_VARIANT
export OPENCODE_CLOUD_MODEL OPENCODE_CLOUD_VARIANT
export OPENCODE_DB_MODEL OPENCODE_DB_VARIANT
export OPENCODE_DEPLOY_MODEL OPENCODE_DEPLOY_VARIANT
export OPENCODE_DEVOPS_MODEL OPENCODE_DEVOPS_VARIANT
export OPENCODE_PERF_MODEL OPENCODE_PERF_VARIANT
export OPENCODE_TEST_AUTOMATOR_MODEL OPENCODE_TEST_AUTOMATOR_VARIANT
export OPENCODE_EXECUTOR_MODEL OPENCODE_EXECUTOR_VARIANT
export OPENCODE_EXPLORE_MODEL OPENCODE_EXPLORE_VARIANT
export OPENCODE_SPEC_REVIEWER_MODEL OPENCODE_SPEC_REVIEWER_VARIANT

# Provider-only profiles ignore the separate legacy free-mode override.
if [ "$PROFILE" = "mixed" ]; then
  check_mixed_subagent_bindings
else
  unset OPENCODE_FREE OPENCODE_FREE_MODEL
fi

if [ "${1:-}" = "--print-env" ]; then
  env | LC_ALL=C sort | grep '^OPENCODE_\(MODEL_PROFILE\|DEFAULT_AGENT\|PRIMARY\|PLAN\|SMALL\|FAST\|LOCATOR\|GENERAL\|ANALYZER\|CONTEXT\|SNIFFER\|FRONTEND\|MOBILE\|BACKEND\|CLOUD\|DB\|DEPLOY\|DEVOPS\|PERF\|TEST_AUTOMATOR\|EXECUTOR\|EXPLORE\|SPEC_REVIEWER\|MAX_CONCURRENT\|FREE\)'
  exit 0
fi

# A private server keeps this launch's environment isolated from other profiles.
exec opencode --standalone "$@"
