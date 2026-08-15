#!/usr/bin/env bash
# Configures OpenCode (CLI and Desktop — they share one config file; see
# docs/OPENCODE.md) to use this repo's vLLM server as a provider, configures
# context compaction/pruning settings, and installs behavioral rules & recovery plugin.
#
# Surgical merge: writes/updates provider["scar-vllm"] and compaction settings
# in the existing opencode.json(c). Everything else in the file (other providers,
# MCP, agents, plugins, preferences) is left exactly as-is. Always backs up the
# file first. Refuses to touch a config file that isn't valid strict JSON
# (e.g. one hand-edited with // comments) rather than risk destroying it.
#
# Usage:
#   scripts/configure-opencode.sh [--endpoint local|lan|<url>] [--profile NAME] [--dry-run]
#   scripts/configure-opencode.sh --skip-rules
#   scripts/configure-opencode.sh --remove
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROVIDER_ID="scar-vllm"
PROVIDER_LABEL="scar.lab vLLM (local)"
PLACEHOLDER_API_KEY="local-no-auth-required" # pragma: allowlist secret -- not a secret, this server has no auth; see docs/OPENCODE.md

ENDPOINT_MODE="local"
PROFILE=""
DRY_RUN=0
REMOVE=0
SKIP_RULES=0
FORCE=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--endpoint local|lan|<url>] [--profile NAME] [--dry-run] [--skip-rules] [--force]
       $(basename "$0") --remove

  --endpoint local|lan|<url>  Where OpenCode should reach the vLLM API.
                              local (default): http://localhost:<API_PORT>/v1
                              lan:             http://\$(hostname):<API_PORT>/v1
                              <url>:           used verbatim (must end in /v1)
  --profile NAME              Model profile to expose (default: DEFAULT_MODEL_PROFILE
                              from .env). Determines the served model name/id.
  --skip-rules                Do not install/update AGENTS.md rules and compaction plugin.
  --force                     Force rewrite even if configuration is already current.
  --dry-run                   Print what would be written; touch nothing.
  --remove                    Delete the "${PROVIDER_ID}" provider entry (rollback).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT_MODE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-rules) SKIP_RULES=1; shift ;;
    --force) FORCE=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_fail "Unknown option: $1"; usage; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { log_fail "'jq' is required but not found on PATH."; exit 1; }

load_env

# --- locate the OpenCode config file ------------------------------------

# Prefer an explicit OPENCODE_CONFIG_DIR override, then the installed CLI's
# own reported config directory; fall back to the documented default.
# OpenCode Desktop reads the same file — see docs/OPENCODE.md.
if [[ -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
  CONFIG_DIR="$OPENCODE_CONFIG_DIR"
elif command -v opencode >/dev/null 2>&1; then
  CONFIG_DIR="$(opencode debug paths 2>/dev/null | awk '$1=="config"{print $2}')"
fi
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/opencode}"

if [[ -f "${CONFIG_DIR}/opencode.jsonc" ]]; then
  CONFIG_PATH="${CONFIG_DIR}/opencode.jsonc"
elif [[ -f "${CONFIG_DIR}/opencode.json" ]]; then
  CONFIG_PATH="${CONFIG_DIR}/opencode.json"
else
  CONFIG_PATH="${CONFIG_DIR}/opencode.json" # created fresh below if needed
fi

# --- --remove --------------------------------------------------------------

if [[ "$REMOVE" -eq 1 ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    log_warn "No OpenCode config found at ${CONFIG_PATH} — nothing to remove."
  else
    if ! jq -e --arg pid "$PROVIDER_ID" '.provider[$pid] // empty' "$CONFIG_PATH" >/dev/null 2>&1; then
      log_warn "Provider '${PROVIDER_ID}' is not present in ${CONFIG_PATH} — nothing to remove."
    else
      backup="${CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$CONFIG_PATH" "$backup"
      tmp="$(mktemp)"
      jq --arg pid "$PROVIDER_ID" 'del(.provider[$pid])' "$CONFIG_PATH" > "$tmp"
      mv "$tmp" "$CONFIG_PATH"
      log_pass "Removed provider '${PROVIDER_ID}' from ${CONFIG_PATH} (backup: ${backup})"
    fi
  fi

  if [[ "$SKIP_RULES" -eq 0 ]]; then
    log_step "Removing managed rules and compaction plugin:"
    "${SCRIPT_DIR}/configure-opencode-rules.sh" --remove
  fi
  exit 0
fi

# --- resolve model profile ---------------------------------------------

[[ -n "$PROFILE" ]] || PROFILE="${DEFAULT_MODEL_PROFILE:-$DEFAULT_MODEL_PROFILE_FALLBACK}"
PROFILE="$(resolve_profile_alias "$PROFILE")"
PROFILE_PATH="$(resolve_model_profile "$PROFILE")"

get_profile_var() { grep "^${1}=" "$PROFILE_PATH" | head -1 | cut -d= -f2-; }
SERVED_MODEL_NAME="$(get_profile_var SERVED_MODEL_NAME)"
MAX_MODEL_LEN="$(get_profile_var MAX_MODEL_LEN)"
[[ -n "$SERVED_MODEL_NAME" ]] || { log_fail "Profile ${PROFILE} has no SERVED_MODEL_NAME — cannot derive OpenCode model id."; exit 1; }

# --- resolve endpoint ----------------------------------------------------

case "$ENDPOINT_MODE" in
  local) BASE_URL="http://localhost:${API_PORT:-8000}/v1" ;;
  lan|remote) BASE_URL="http://$(hostname):${API_PORT:-8000}/v1" ;;
  http://*|https://*) BASE_URL="$ENDPOINT_MODE" ;;
  *) log_fail "Unknown --endpoint value: '${ENDPOINT_MODE}' (expected local, lan, or a http(s):// URL)"; exit 1 ;;
esac

# --- build the provider and compaction blocks -----------------------------

# OpenCode has no way to know our server's --max-model-len and otherwise
# defaults to requesting a large max_tokens (seen live: 32000), which vLLM
# rejects outright once it exceeds max_model_len. `limit.context`/`limit.output`
# tell OpenCode the real ceiling. output is capped well below the full
# context to leave room for the prompt/tool-call history — a quarter of
# context is a reasonable default for coding-agent-style usage.
[[ "$MAX_MODEL_LEN" =~ ^[0-9]+$ ]] || { log_fail "Profile ${PROFILE} has a non-numeric MAX_MODEL_LEN ('${MAX_MODEL_LEN}')"; exit 1; }
OUTPUT_LIMIT=$(( MAX_MODEL_LEN / 4 ))

NEW_PROVIDER="$(jq -n \
  --arg name "$PROVIDER_LABEL" \
  --arg baseURL "$BASE_URL" \
  --arg apiKey "$PLACEHOLDER_API_KEY" \
  --arg modelId "$SERVED_MODEL_NAME" \
  --arg modelName "${SERVED_MODEL_NAME} via vLLM/scar.lab (max ${MAX_MODEL_LEN} ctx)" \
  --argjson context "$MAX_MODEL_LEN" \
  --argjson output "$OUTPUT_LIMIT" \
  '{
    npm: "@ai-sdk/openai-compatible",
    name: $name,
    options: { baseURL: $baseURL, apiKey: $apiKey },
    models: {
      ($modelId): {
        name: $modelName,
        tool_call: true,
        limit: { context: $context, output: $output }
      }
    }
  }')"

log_step "Profile: ${PROFILE}  ->  OpenCode model: ${PROVIDER_ID}/${SERVED_MODEL_NAME}"
log_info "Endpoint: ${BASE_URL}"
log_info "Config file: ${CONFIG_PATH}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_step "Dry run — would write provider block and compaction configuration (nothing touched):"
  jq -n \
    --arg pid "$PROVIDER_ID" \
    --argjson prov "$NEW_PROVIDER" \
    '{
      provider: {($pid): $prov},
      compaction: {
        auto: true,
        prune: true,
        reserved: 2000
      }
    }'
  if [[ "$SKIP_RULES" -eq 0 ]]; then
    log_step "Dry run — behavioral rules and compaction plugin:"
    "${SCRIPT_DIR}/configure-opencode-rules.sh" --dry-run
  fi
  exit 0
fi

# --- write, preserving everything else ------------------------------------

if [[ -f "$CONFIG_PATH" ]]; then
  if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    log_fail "${CONFIG_PATH} is not valid strict JSON (it may contain // or /* */ comments)."
    log_info "Refusing to auto-merge — a jq round-trip would silently delete those comments."
    log_info "Merge this block into it by hand instead:"
    jq -n --arg pid "$PROVIDER_ID" --argjson prov "$NEW_PROVIDER" '{provider: {($pid): $prov}}'
    exit 1
  fi
else
  mkdir -p "$CONFIG_DIR"
  # shellcheck disable=SC2016 # literal $schema JSON key, not a shell variable
  printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$CONFIG_PATH"
  log_info "No existing OpenCode config found — created a fresh one at ${CONFIG_PATH}"
fi

# Check if changes are actually needed before creating backup
tmp="$(mktemp)"
jq --arg pid "$PROVIDER_ID" --argjson prov "$NEW_PROVIDER" '
  .provider = ((.provider // {}) + {($pid): $prov}) |
  .compaction = ((.compaction // {}) + {
    auto: true,
    prune: true,
    reserved: (.compaction.reserved // 2000)
  })
' "$CONFIG_PATH" > "$tmp"

if cmp -s "$CONFIG_PATH" "$tmp" && [[ "$FORCE" -eq 0 ]]; then
  rm -f "$tmp"
  log_pass "OpenCode config already up to date: ${CONFIG_PATH}"
else
  backup="${CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$CONFIG_PATH" "$backup"
  mv "$tmp" "$CONFIG_PATH"
  log_pass "Wrote provider '${PROVIDER_ID}' and compaction configuration to ${CONFIG_PATH} (backup: ${backup})"
fi

# --- install rules and compaction plugin ----------------------------------

if [[ "$SKIP_RULES" -eq 0 ]]; then
  log_step "Installing behavioral rules and compaction recovery plugin:"
  if [[ "$FORCE" -eq 1 ]]; then
    "${SCRIPT_DIR}/configure-opencode-rules.sh" --force
  else
    "${SCRIPT_DIR}/configure-opencode-rules.sh"
  fi
fi

# --- validation -----------------------------------------------------------

if command -v opencode >/dev/null 2>&1; then
  log_step "Validating with 'opencode models'"
  if opencode models 2>/dev/null | grep -qF "${PROVIDER_ID}/${SERVED_MODEL_NAME}"; then
    log_pass "OpenCode sees ${PROVIDER_ID}/${SERVED_MODEL_NAME}"
  else
    log_warn "OpenCode CLI didn't list ${PROVIDER_ID}/${SERVED_MODEL_NAME} — check ${CONFIG_PATH} and 'opencode debug config'"
  fi
else
  log_warn "opencode CLI not found on PATH — skipped live validation. Restart OpenCode Desktop to pick up this change."
fi

log_info "Test: opencode run --model ${PROVIDER_ID}/${SERVED_MODEL_NAME} \"say hi in one word\""
log_info "Verify: ${SCRIPT_DIR}/verify-opencode.sh"
log_info "Rollback: scripts/configure-opencode.sh --remove"
