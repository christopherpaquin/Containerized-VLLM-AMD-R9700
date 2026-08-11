#!/usr/bin/env bash
# Checks the OpenAI-compatible API: GET /v1/models, and optionally a tiny
# chat completion to confirm inference actually works end to end.
#
# Usage: scripts/healthcheck.sh [--full]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

load_env
url="$(api_base_url)"

log_step "GET ${url}/v1/models"
if ! models_json="$(curl -fsS --max-time 10 "${url}/v1/models" 2>&1)"; then
  log_fail "Request failed: ${models_json}"
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  model_id="$(printf '%s' "$models_json" | jq -r '.data[0].id // empty')"
  printf '%s\n' "$models_json" | jq .
else
  model_id="$(printf '%s' "$models_json" | grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  printf '%s\n' "$models_json"
fi

if [[ -z "$model_id" ]]; then
  log_fail "/v1/models responded but no model id was found in the response"
  exit 1
fi
log_pass "/v1/models OK — served model: ${model_id}"

if [[ "$FULL" -eq 0 ]]; then
  exit 0
fi

log_step "POST ${url}/v1/chat/completions (model=${model_id})"
payload=$(cat <<JSON
{"model": "${model_id}", "messages": [{"role": "user", "content": "Reply with exactly one word: OK"}], "max_tokens": 8, "temperature": 0}
JSON
)
if ! response="$(curl -fsS --max-time 60 -X POST "${url}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$payload" 2>&1)"; then
  log_fail "Chat completion request failed: ${response}"
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$response" | jq .
else
  printf '%s\n' "$response"
fi
log_pass "Chat completion request succeeded"
