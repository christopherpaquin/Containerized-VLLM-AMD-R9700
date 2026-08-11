#!/usr/bin/env bash
# Starts vLLM with the given model profile, or the repo default if none is
# given (DEFAULT_MODEL_PROFILE in .env, falling back to qwen3-coder-30b-a3b).
#
# Usage: scripts/start.sh [model-profile] [--skip-preflight] [--no-wait]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [model-profile] [--skip-preflight] [--no-wait]

With no model-profile, starts DEFAULT_MODEL_PROFILE from .env (currently
falls back to ${DEFAULT_MODEL_PROFILE_FALLBACK} if unset).

Available model profiles:
$(list_model_profiles | sed 's/^/  - /')
EOF
}

PROFILE=""
SKIP_PREFLIGHT=0
NO_WAIT=0

for arg in "$@"; do
  case "$arg" in
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    --no-wait) NO_WAIT=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) log_fail "Unknown option: $arg"; usage; exit 1 ;;
    *)
      if [[ -n "$PROFILE" ]]; then
        log_fail "Multiple profiles given: '$PROFILE' and '$arg'"
        usage
        exit 1
      fi
      PROFILE="$arg"
      ;;
  esac
done

if [[ -z "$PROFILE" ]]; then
  load_env
  PROFILE="${DEFAULT_MODEL_PROFILE:-$DEFAULT_MODEL_PROFILE_FALLBACK}"
  log_step "No model profile given — using default: ${PROFILE}"
fi
PROFILE="$(resolve_profile_alias "$PROFILE")"

PROFILE_PATH="$(resolve_model_profile "$PROFILE")"
require_env_file

if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
  log_step "Running preflight checks"
  if ! "${SCRIPT_DIR}/preflight.sh"; then
    log_fail "Preflight failed. Fix the issues above, or re-run with --skip-preflight to proceed anyway."
    exit 1
  fi
else
  log_warn "Skipping preflight checks (--skip-preflight)"
fi

log_step "Selected model profile: ${PROFILE}"
log_info "Profile settings (${PROFILE_PATH}):"
grep -vE '^\s*(#|$)' "$PROFILE_PATH" | sed 's/^/  /' >&2

export MODEL_PROFILE="$PROFILE"
save_current_profile "$PROFILE"

log_step "Starting Docker Compose"
if ! compose up -d; then
  log_fail "docker compose up failed. See the error above — this is the raw Docker/Compose output, not summarized."
  exit 1
fi

load_env
url="$(api_base_url)"
log_step "Container starting. API will be available at: ${url}"
log_info "Model loading can take a while on first run (download + VRAM load), especially for the 30B profile."

if [[ "$NO_WAIT" -eq 1 ]]; then
  log_info "Not waiting for health (--no-wait). Check with: scripts/status.sh or scripts/healthcheck.sh"
  exit 0
fi

log_step "Waiting for API to become healthy (up to 10 minutes)..."
elapsed=0
timeout=600
interval=5
until curl -fsS "${url}/v1/models" >/dev/null 2>&1; do
  if [[ "$elapsed" -ge "$timeout" ]]; then
    log_fail "API did not become healthy within ${timeout}s."
    log_info "Check logs with: docker compose logs -f (MODEL_PROFILE=${PROFILE})"
    exit 1
  fi
  # Fail fast if the container itself died instead of silently polling forever.
  state="$(compose ps --format '{{.State}}' vllm 2>/dev/null || true)"
  if [[ "$state" == "exited" || "$state" == "dead" ]]; then
    log_fail "Container exited unexpectedly while waiting for health. Logs:"
    compose logs --tail=100 vllm >&2 || true
    exit 1
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

log_pass "vLLM is up: ${url}"
log_info "Try: curl ${url}/v1/models"
