#!/usr/bin/env bash
# Workstation coexistence benchmark: records real GPU/VRAM state across
# desktop-idle, vLLM-idle, desktop-apps-open, and desktop-apps+inference
# checkpoints. This is the actual thing the VRAM budget in docs/TUNING.md
# exists to protect — a --gpu-memory-utilization number alone doesn't tell
# you whether the desktop stays usable; this script measures it.
#
# The desktop-app checkpoints are interactive by design: opening a real
# browser/IDE is more representative than trying to script GUI automation,
# and far less fragile.
#
# Usage: scripts/workstation-benchmark.sh [--skip-desktop-apps] [--concurrency N]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

command -v rocm-smi >/dev/null 2>&1 || { log_fail "rocm-smi not found on host — this benchmark needs host-side GPU metrics. See docs/ROCM.md."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_fail "'jq' is required but not found on PATH."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_fail "'curl' is required but not found on PATH."; exit 1; }

CONCURRENCY=4
SKIP_DESKTOP=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--skip-desktop-apps] [--concurrency N]

  --skip-desktop-apps   Only measure vLLM idle vs. vLLM under inference load
                         (no interactive prompts). Useful for a quick/CI-ish check.
  --concurrency N        Concurrent requests used for the inference-load
                         checkpoints (default: 4).

Requires vLLM already running and healthy (scripts/start.sh first).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-desktop-apps) SKIP_DESKTOP=1; shift ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_fail "Unknown option: $1"; usage; exit 1 ;;
  esac
done

load_env
url="$(api_base_url)"

if ! models_json="$(curl -fsS --max-time 10 "${url}/v1/models" 2>&1)"; then
  log_fail "vLLM API not reachable at ${url}. Start it first: scripts/start.sh"
  exit 1
fi
model_id="$(printf '%s' "$models_json" | jq -r '.data[0].id // empty')"

# --- snapshot helper -------------------------------------------------------

snapshot() {
  local label="$1"
  local m
  m="$(rocm-smi --showmeminfo vram --showuse --showtemp --showpower --json 2>/dev/null | jq -c '.card0 // .[keys[0]]')"
  jq -c -n --arg label "$label" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson m "$m" \
    '{label: $label, timestamp: $ts} + $m'
}

# Fires CONCURRENCY chat completions with a long-ish max_tokens in the
# background so there's real, sustained GPU activity to snapshot mid-flight,
# then waits for them all to finish before returning.
run_inference_load() {
  local pids=()
  local _i
  for _i in $(seq 1 "$CONCURRENCY"); do
    (
      curl -s --max-time 60 -X POST "${url}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg m "$model_id" '{model:$m, messages:[{role:"user",content:"Write a detailed, step-by-step explanation of how a hash table resolves collisions, with an example."}], max_tokens: 400, temperature: 0}')" \
        >/dev/null 2>&1
    ) &
    pids+=($!)
  done
  # Give generation time to actually ramp up before the caller snapshots.
  sleep 2
  printf '%s\n' "${pids[@]}"
}

wait_pids() { local p; for p in "$@"; do wait "$p" 2>/dev/null || true; done; }

checkpoints_file="$(mktemp)"
trap 'rm -f "$checkpoints_file"' EXIT

add_checkpoint() { snapshot "$1" >> "$checkpoints_file"; }

log_step "Model under test: ${model_id}"

log_step "Checkpoint: vLLM loaded, idle"
sleep 1
add_checkpoint "vllm_idle"

if [[ "$SKIP_DESKTOP" -eq 0 ]]; then
  echo
  echo "Open your normal browser and IDE now — however you'd actually use this"
  echo "workstation day to day — then press Enter to continue."
  read -r -p "> " _ || true
  log_step "Checkpoint: desktop apps open, vLLM idle"
  add_checkpoint "desktop_apps_open"
else
  log_warn "Skipping desktop-app checkpoints (--skip-desktop-apps)"
fi

log_step "Checkpoint: inference active (vLLM only, ${CONCURRENCY} concurrent requests)"
mapfile -t pids < <(run_inference_load)
add_checkpoint "inference_active"
wait_pids "${pids[@]}"

if [[ "$SKIP_DESKTOP" -eq 0 ]]; then
  log_step "Checkpoint: desktop apps + inference simultaneously"
  mapfile -t pids < <(run_inference_load)
  add_checkpoint "desktop_apps_plus_inference"
  wait_pids "${pids[@]}"
fi

# --- report ----------------------------------------------------------------

echo
printf '%-30s %10s %10s %8s %8s\n' "Checkpoint" "VRAM used" "VRAM free" "GPU %" "Temp C"
printf '%-30s %10s %10s %8s %8s\n' "----------" "---------" "---------" "-----" "------"
while IFS= read -r line; do
  jq -r '
    (.["VRAM Total Memory (B)"] | tonumber) as $total |
    (.["VRAM Total Used Memory (B)"] | tonumber) as $used |
    [ .label,
      (($used / 1073741824 * 100 | round) / 100 | tostring) + " GiB",
      ((($total - $used) / 1073741824 * 100 | round) / 100 | tostring) + " GiB",
      (.["GPU use (%)"] // "n/a"),
      (.["Temperature (Sensor edge) (C)"] // "n/a")
    ] | @tsv' <<<"$line"
done < "$checkpoints_file" | while IFS=$'\t' read -r label used free gpu temp; do
  printf '%-30s %10s %10s %8s %8s\n' "$label" "$used" "$free" "${gpu}%" "$temp"
done

results_dir="${REPO_ROOT}/benchmarks/results"
mkdir -p "$results_dir"
out_file="${results_dir}/$(date -u +%Y%m%dT%H%M%SZ)_workstation-coexistence.json"
jq -s --arg model "$model_id" --argjson concurrency "$CONCURRENCY" \
  '{model: $model, concurrency: $concurrency, checkpoints: .}' "$checkpoints_file" | tee "$out_file" >/dev/null

echo
log_pass "Results written to ${out_file}"
log_info "Note: this does not include a true 'desktop idle, vLLM not running' baseline —"
log_info "vLLM is expected to stay running (see README). That baseline was measured"
log_info "separately on scar.lab at ~1.3-1.4 GiB used; see docs/BENCHMARKING.md."
