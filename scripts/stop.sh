#!/usr/bin/env bash
# Gracefully stops vLLM. Does not remove the Hugging Face cache volume/data.
#
# Usage: scripts/stop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="$(load_current_profile)"
if [[ -z "$PROFILE" ]]; then
  log_warn "No remembered model profile (nothing started via scripts/start.sh?). Trying compose down anyway with an empty profile — this may no-op."
fi

export MODEL_PROFILE="$PROFILE"

log_step "Stopping vLLM"
compose down
log_pass "Stopped."
