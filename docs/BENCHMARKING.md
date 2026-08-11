# Benchmarking

`scripts/benchmark.sh` produces one repeatable measurement per invocation
against whatever model is currently running (`scripts/start.sh` must have
been run first). It is intentionally simple — a foundation to build on, not
a full load-testing suite.

## What it measures, and how

| Field | How it's obtained |
|---|---|
| TTFT | **Phase 1**: N concurrent streaming (`"stream": true`) chat completion requests, response bodies discarded, timed with curl's own `time_starttransfer` (time to first byte). This approximates true time-to-first-token — a client-measured, curl-native proxy, not server-side instrumentation. Good enough for relative comparisons (before/after a tuning change); don't treat it as a lab-grade absolute number. |
| Token counts, latency, throughput | **Phase 2**: N concurrent non-streaming requests (same prompt/params), using the API response's own `usage.prompt_tokens` / `usage.completion_tokens` as ground truth, and curl's `time_total` for per-request latency. |
| Prompt size | Approximate. The script pads a filler sentence to roughly hit `--prompt-tokens` (using a ~1.3-tokens-per-word heuristic), then records the *actual* `prompt_tokens` the API reports. Don't expect exact token counts — the recorded `avg_prompt_tokens` in the output is the real number that matters. |
| Concurrency | N parallel backgrounded requests (bash job control), aggregated. `aggregate_tokens_per_sec` = total completion tokens across all requests ÷ wall-clock time of the batch — this is the throughput number that actually reflects concurrency; the per-request `avg_latency_seconds` does not. |
| vLLM / ROCm versions, container image | Queried from the running container (`docker compose exec`) and `.env`, not hardcoded. |
| VRAM usage | `rocm-smi` on the **host**, at the time the benchmark runs — requires ROCm tools installed on the host (same caveat as `scripts/gpu-info.sh`). Records `"unknown"` if unavailable rather than failing the whole benchmark. |
| GPU config (context, quantization, KV cache dtype, memory utilization) | Read directly from the model profile file, so results are traceable back to exactly what was running. |

TTFT and throughput are measured in **two separate phases**, each with its
own wall-clock, rather than one request per phase sharing a single
wall-clock. Sharing a clock across both was tried first and produces a
silently diluted throughput number — `aggregate_tokens_per_sec` would divide
real completion tokens by wall-clock time that also includes a streaming
request whose tokens aren't counted. Caught by running this against a real
server on `scar.lab`: measured throughput was roughly half of actual until
this was fixed. Two API calls per data point either way — simpler than
parsing token usage out of an SSE stream — just no longer sharing a clock.

## Usage

```bash
scripts/benchmark.sh qwen25-coder-14b --concurrency 1 --prompt-tokens 512 --max-tokens 256
```

Options: `--concurrency N` (default 1), `--prompt-tokens N` (default 512,
approximate — see above), `--max-tokens N` (default 256, caps completion
length so runs stay fast and comparable).

Requires `jq`, `curl`, and `bc` on the host (not in the container).

## Running the concurrency × prompt-size matrix

The task plan calls for eventually covering concurrency {1, 4, 8} and prompt
sizes {~512, ~4K, ~8K}. `scripts/benchmark.sh` deliberately does one point at
a time — loop over it externally:

```bash
for c in 1 4 8; do
  for p in 512 4096 8192; do
    scripts/benchmark.sh qwen25-coder-14b --concurrency "$c" --prompt-tokens "$p"
  done
done
```

Keep `--max-tokens` fixed across a comparison run so completion length isn't
a confounding variable.

## Where results go

- `benchmarks/results/<timestamp>_<profile>_c<N>_p<N>.json` — one
  self-contained file per run, with all the metadata above.
- `benchmarks/results/results.csv` — one row appended per run, for quick
  spreadsheet/`pandas` comparison across runs. Header is written the first
  time the file is created.

Individual result files aren't committed by default (see `.gitignore`) —
raw benchmark output can accumulate quickly and isn't generally meaningful
outside the machine/GPU state it was captured on. Commit specific curated
results deliberately (`git add -f`) if you want to preserve a particular
baseline for comparison in the repo itself.

## Known limitations (this is the "start simple" baseline)

- No latency percentiles (p50/p95/p99) — only means. Fine for now, but a
  real evaluation of tail latency under concurrency will need this.
- No sustained/soak testing — each run is a single batch of N concurrent
  requests, not a steady-state load test.
- No quality/correctness evaluation — this measures speed, not whether the
  model's output is any good. That's a separate concern.
- TTFT and token-count requests are two separate API calls per data point
  (see above) — under high concurrency this means `benchmark.sh` itself
  generates 2×N requests, which is worth remembering when interpreting
  server-side load during a run.

Extend this script rather than replacing it wholesale when these limitations
start to matter.

## `scripts/workstation-benchmark.sh` — desktop coexistence

Different question from `benchmark.sh`: not "how fast is inference" but "how
much VRAM is actually left for the desktop, under real desktop use." Records
GPU snapshots (VRAM used/free, utilization, temperature, power via
`rocm-smi --json`) at up to four checkpoints:

1. vLLM loaded, idle
2. desktop apps open, vLLM idle (interactive — see below)
3. inference active (vLLM only, N concurrent requests)
4. desktop apps + inference simultaneously (interactive)

```bash
scripts/workstation-benchmark.sh                     # full, interactive
scripts/workstation-benchmark.sh --skip-desktop-apps  # vLLM-only checkpoints, no prompts
scripts/workstation-benchmark.sh --concurrency 8
```

The desktop-app checkpoints are **interactive by design** — the script
prints "open your normal browser and IDE now, then press Enter" rather than
scripting GUI automation. Automating real desktop apps (window management,
waiting for them to actually render, dealing with Wayland vs. X11) is
fragile and environment-specific in a way that just asking a human (or an
agent sitting at the actual desktop) to open their normal apps isn't.

Inference load is generated the same way `benchmark.sh` does — real
concurrent chat completion requests, not synthetic GPU load — with a large
enough `max_tokens` that there's genuine sustained generation to snapshot
mid-flight rather than a request that's already finished.

**Live result on `scar.lab`** (Qwen3-Coder-30B-A3B, `--concurrency 4`, real
Firefox + VS Code open): VRAM free held stable at **~7.5 GiB across all four
checkpoints** — desktop apps opening didn't measurably move it, and neither
did active inference. This confirms what docs/TUNING.md describes
structurally: vLLM's footprint is fixed once the KV cache pool is reserved
at startup, so "VRAM used right after model load" is already the number
that matters, not a lower bound that inference load pushes higher.

This script does not include a true "desktop idle, vLLM not running"
baseline checkpoint, since vLLM is meant to stay running persistently (see
README "Startup behavior") — stopping it just to measure that would be a
purposeless restart. That number was captured separately, once, before vLLM
was ever started on this host: **~1.3-1.4 GiB** used at idle.

Results save to `benchmarks/results/<timestamp>_workstation-coexistence.json`.
