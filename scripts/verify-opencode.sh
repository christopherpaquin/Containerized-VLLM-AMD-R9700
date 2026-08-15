#!/usr/bin/env bash
# Verifies OpenCode configuration for the local vLLM environment:
# - OpenCode CLI installation
# - opencode.json(c) syntax and structure
# - scar-vllm provider and model wiring (tool calling, limits)
# - Compaction and tool output pruning configuration
# - Global AGENTS.md behavioral rules and managed block integrity
# - Custom compaction recovery plugin installation
#
# Usage:
#   scripts/verify-opencode.sh [--profile NAME] [--config-dir DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROVIDER_ID="scar-vllm"
PROFILE=""
CONFIG_DIR_OVERRIDE=""
FAILURES=0
WARNINGS=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--profile NAME] [--config-dir DIR]

  --profile NAME      Model profile to verify against (default: DEFAULT_MODEL_PROFILE).
  --config-dir DIR    Explicit OpenCode config directory to verify.
  -h, --help          Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --config-dir) CONFIG_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_fail "Unknown option: $1"; usage; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { log_fail "'jq' is required for verification."; exit 1; }

load_env

# --- resolve profile ------------------------------------------------------

[[ -n "$PROFILE" ]] || PROFILE="${DEFAULT_MODEL_PROFILE:-$DEFAULT_MODEL_PROFILE_FALLBACK}"
PROFILE="$(resolve_profile_alias "$PROFILE")"
PROFILE_PATH="$(resolve_model_profile "$PROFILE")"

get_profile_var() { grep "^${1}=" "$PROFILE_PATH" | head -1 | cut -d= -f2-; }
SERVED_MODEL_NAME="$(get_profile_var SERVED_MODEL_NAME)"
MAX_MODEL_LEN="$(get_profile_var MAX_MODEL_LEN)"

# --- resolve config directory ---------------------------------------------

if [[ -n "$CONFIG_DIR_OVERRIDE" ]]; then
  CONFIG_DIR="$CONFIG_DIR_OVERRIDE"
elif [[ -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
  CONFIG_DIR="$OPENCODE_CONFIG_DIR"
elif command -v opencode >/dev/null 2>&1; then
  CONFIG_DIR="$(opencode debug paths 2>/dev/null | awk '$1=="config"{print $2}')"
fi
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/opencode}"

CONFIG_PATH=""
if [[ -f "${CONFIG_DIR}/opencode.jsonc" ]]; then
  CONFIG_PATH="${CONFIG_DIR}/opencode.jsonc"
elif [[ -f "${CONFIG_DIR}/opencode.json" ]]; then
  CONFIG_PATH="${CONFIG_DIR}/opencode.json"
fi

GLOBAL_RULES="${CONFIG_DIR}/AGENTS.md"
GLOBAL_PLUGIN="${CONFIG_DIR}/plugins/compaction-recovery.js"
BEGIN_MARKER="<!-- BEGIN SCAR-VLLM MANAGED RULES -->"
END_MARKER="<!-- END SCAR-VLLM MANAGED RULES -->"

log_step "Verifying OpenCode configuration"
log_info "Model profile: ${PROFILE} (${SERVED_MODEL_NAME}, ctx ${MAX_MODEL_LEN})"
log_info "Config dir:    ${CONFIG_DIR}"

# 1. OpenCode installation
if command -v opencode >/dev/null 2>&1; then
  OPENCODE_VER="$(opencode --version 2>/dev/null || echo "unknown")"
  log_pass "OpenCode CLI installed (${OPENCODE_VER})"
else
  log_warn "OpenCode CLI binary not found on PATH (OpenCode Desktop may still be installed)"
  ((WARNINGS++)) || true
fi

# 2. Config file exists and is valid JSON
if [[ -z "$CONFIG_PATH" || ! -f "$CONFIG_PATH" ]]; then
  log_fail "OpenCode config file not found in ${CONFIG_DIR} (expected opencode.json or opencode.jsonc)"
  ((FAILURES++)) || true
else
  if jq empty "$CONFIG_PATH" 2>/dev/null; then
    log_pass "Config file is valid strict JSON: ${CONFIG_PATH}"
  else
    log_fail "Config file ${CONFIG_PATH} is not valid JSON (may contain comments or syntax errors)"
    ((FAILURES++)) || true
  fi
fi

# 3. Provider and model configuration
if [[ -n "$CONFIG_PATH" && -f "$CONFIG_PATH" ]] && jq empty "$CONFIG_PATH" 2>/dev/null; then
  if jq -e --arg pid "$PROVIDER_ID" '.provider[$pid] // empty' "$CONFIG_PATH" >/dev/null 2>&1; then
    log_pass "Provider '${PROVIDER_ID}' is configured in ${CONFIG_PATH}"

    # Check baseURL
    BASE_URL="$(jq -r --arg pid "$PROVIDER_ID" '.provider[$pid].options.baseURL // empty' "$CONFIG_PATH")"
    if [[ "$BASE_URL" =~ ^https?://.+/v1$ ]]; then
      log_pass "Provider baseURL is valid: ${BASE_URL}"
    else
      log_fail "Provider baseURL is invalid or missing: '${BASE_URL}' (must end in /v1)"
      ((FAILURES++)) || true
    fi

    # Check model entry
    if jq -e --arg pid "$PROVIDER_ID" --arg mid "$SERVED_MODEL_NAME" '.provider[$pid].models[$mid] // empty' "$CONFIG_PATH" >/dev/null 2>&1; then
      log_pass "Model '${SERVED_MODEL_NAME}' is configured under provider '${PROVIDER_ID}'"

      TOOL_CALL="$(jq -r --arg pid "$PROVIDER_ID" --arg mid "$SERVED_MODEL_NAME" '.provider[$pid].models[$mid].tool_call // false' "$CONFIG_PATH")"
      if [[ "$TOOL_CALL" == "true" ]]; then
        log_pass "Model tool_call is enabled (tool_call: true)"
      else
        log_fail "Model tool_call is not enabled (required for agentic operation)"
        ((FAILURES++)) || true
      fi

      CTX_LIMIT="$(jq -r --arg pid "$PROVIDER_ID" --arg mid "$SERVED_MODEL_NAME" '.provider[$pid].models[$mid].limit.context // empty' "$CONFIG_PATH")"
      OUT_LIMIT="$(jq -r --arg pid "$PROVIDER_ID" --arg mid "$SERVED_MODEL_NAME" '.provider[$pid].models[$mid].limit.output // empty' "$CONFIG_PATH")"
      if [[ "$CTX_LIMIT" =~ ^[0-9]+$ && "$CTX_LIMIT" -gt 0 ]]; then
        log_pass "Context limit configured: ${CTX_LIMIT} tokens"
      else
        log_fail "Invalid or missing limit.context: '${CTX_LIMIT}'"
        ((FAILURES++)) || true
      fi

      if [[ "$OUT_LIMIT" =~ ^[0-9]+$ && "$OUT_LIMIT" -gt 0 ]]; then
        log_pass "Output limit configured: ${OUT_LIMIT} tokens"
      else
        log_fail "Invalid or missing limit.output: '${OUT_LIMIT}'"
        ((FAILURES++)) || true
      fi
    else
      log_fail "Model '${SERVED_MODEL_NAME}' is missing from provider '${PROVIDER_ID}' in ${CONFIG_PATH}"
      ((FAILURES++)) || true
    fi
  else
    log_fail "Provider '${PROVIDER_ID}' is missing from ${CONFIG_PATH}"
    ((FAILURES++)) || true
  fi

  # 4. Compaction configuration
  COMPACT_AUTO="$(jq -r '.compaction.auto // false' "$CONFIG_PATH")"
  COMPACT_PRUNE="$(jq -r '.compaction.prune // false' "$CONFIG_PATH")"
  COMPACT_RESERVED="$(jq -r '.compaction.reserved // empty' "$CONFIG_PATH")"

  if [[ "$COMPACT_AUTO" == "true" ]]; then
    log_pass "Automatic context compaction is enabled (compaction.auto: true)"
  else
    log_fail "Automatic context compaction is not enabled (compaction.auto: ${COMPACT_AUTO})"
    ((FAILURES++)) || true
  fi

  if [[ "$COMPACT_PRUNE" == "true" ]]; then
    log_pass "Tool output pruning is enabled (compaction.prune: true)"
  else
    log_fail "Tool output pruning is not enabled (compaction.prune: ${COMPACT_PRUNE})"
    ((FAILURES++)) || true
  fi

  if [[ "$COMPACT_RESERVED" =~ ^[0-9]+$ && "$COMPACT_RESERVED" -gt 0 ]]; then
    log_pass "Compaction reserved buffer configured: ${COMPACT_RESERVED} tokens"
  else
    log_warn "compaction.reserved not explicitly configured (using OpenCode default buffer)"
    ((WARNINGS++)) || true
  fi
fi

# 5. Global behavioral rules (AGENTS.md)
if [[ -f "$GLOBAL_RULES" ]]; then
  begin_count="$(grep -Fc "$BEGIN_MARKER" "$GLOBAL_RULES" || true)"
  end_count="$(grep -Fc "$END_MARKER" "$GLOBAL_RULES" || true)"

  if [[ "$begin_count" -eq 1 && "$end_count" -eq 1 ]]; then
    log_pass "Global behavioral rules installed with valid managed block markers in ${GLOBAL_RULES}"

    # Check for critical sections inside the file
    if grep -qF "Execution discipline" "$GLOBAL_RULES" && grep -qF "Post-compaction recovery behavior" "$GLOBAL_RULES"; then
      log_pass "AGENTS.md contains Execution Discipline and Post-Compaction Recovery rules"
    else
      log_warn "AGENTS.md is missing some updated execution discipline sections"
      ((WARNINGS++)) || true
    fi
  elif [[ "$begin_count" -eq 0 ]]; then
    log_fail "Managed rules block missing from ${GLOBAL_RULES} (run scripts/configure-opencode-rules.sh)"
    ((FAILURES++)) || true
  else
    log_fail "Found ${begin_count} begin markers and ${end_count} end markers in ${GLOBAL_RULES} (corrupted/duplicate markers)"
    ((FAILURES++)) || true
  fi
else
  log_fail "Global rules file does not exist: ${GLOBAL_RULES}"
  ((FAILURES++)) || true
fi

# 6. Compaction recovery plugin
if [[ -f "$GLOBAL_PLUGIN" ]]; then
  if grep -qF "experimental.session.compacting" "$GLOBAL_PLUGIN" && grep -qF "CURRENT OBJECTIVE" "$GLOBAL_PLUGIN"; then
    log_pass "Compaction recovery plugin installed and verified: ${GLOBAL_PLUGIN}"
  else
    log_fail "Compaction recovery plugin ${GLOBAL_PLUGIN} exists but lacks required hook content"
    ((FAILURES++)) || true
  fi
else
  log_fail "Compaction recovery plugin missing at ${GLOBAL_PLUGIN}"
  ((FAILURES++)) || true
fi

# --- summary --------------------------------------------------------------

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  log_pass "OpenCode verification succeeded (0 failures, ${WARNINGS} warnings)."
  exit 0
else
  log_fail "OpenCode verification failed with ${FAILURES} error(s) and ${WARNINGS} warning(s)."
  log_info "Fix with: scripts/configure-opencode.sh"
  exit 1
fi
