# Tuning

## Why VRAM is deliberately capped, not maximized

`scar.lab` is a daily-use graphical workstation, not a dedicated inference
box. The default Qwen3-Coder profile uses `GPU_MEMORY_UTILIZATION=0.68` —
chosen from a live sweep on `scar.lab`, not a round-number guess. A
dedicated inference server would typically push this to 0.90-0.95; that
would starve the desktop here.

## The utilization sweep (Qwen3-Coder-30B-A3B, real measurements)

`--gpu-memory-utilization` is a *target*, not the number that ends up used —
real total VRAM (rocm-smi, whole-system) runs a few GiB over the nominal
percentage, because graph-capture buffers and allocator overhead sit outside
vLLM's own weights+KV-cache accounting. So every row below is what was
actually measured after a real `scripts/start.sh` + `scripts/gpu-info.sh`,
not `utilization × 32 GiB`. **This sweep was run at the profile's original
16K context** (see "Context length was raised to 32K" below) — the
utilization/VRAM-used/desktop-reserve columns are still the relevant
evidence for the 0.68 choice and were re-confirmed at 32K afterward; the
KV-cache-tokens/concurrency columns are 16K-specific and don't carry over
(32K roughly halves both, as expected):

| `GPU_MEMORY_UTILIZATION` | Real VRAM used | Desktop reserve | KV cache @ 16K | Concurrency @ 16K | tok/s (c=1) |
|---|---|---|---|---|---|
| 0.72 | 25.12 GiB | 6.74 GiB | 63,152 tok | 3.85x | 42.4 |
| **0.68 (chosen)** | **23.88 GiB** | **7.98 GiB** | **50,400 tok** | **3.08x** | **42.6** |
| 0.65 | 22.80 GiB | 9.06 GiB | 39,792 tok | 2.43x | 43.1 |

Single-stream throughput/TTFT were statistically identical across all three
(~42-43 tok/s, ~0.03-0.04s TTFT) — the tradeoff here is entirely about
concurrency/context headroom, not per-request speed, because KV cache
capacity doesn't affect a single request's own generation speed. 0.68 was
chosen because it hits the ~7-8 GiB desktop-reserve target almost exactly
while keeping most of the concurrency headroom — going to 0.65 buys only
~1 GiB more reserve for a disproportionate ~21% concurrency cut, which is
exactly the "small gain, real cost" tradeoff worth avoiding.

## `--gpu-memory-utilization` vs `--kv-cache-memory-bytes`

vLLM 0.23 also exposes `--kv-cache-memory-bytes` — an explicit KV cache size
in bytes, as an alternative to letting `--gpu-memory-utilization` derive it.
Both were tested live on the 30B profile:

| Mechanism | Real VRAM used | Desktop reserve | KV cache |
|---|---|---|---|
| `--gpu-memory-utilization 0.68` | 23.88 GiB | 7.98 GiB | 50,400 tok |
| `--kv-cache-memory-bytes 4831838208` (4.5 GiB) | 23.65 GiB | 8.21 GiB | 49,152 tok |

Comparable outcomes, but two reasons `--gpu-memory-utilization` stays the
default:

1. **It adapts per model automatically.** A fixed byte count tuned for the
   30B profile's ~15.7 GiB weights would be wrong for the 14B profile's
   ~9.4 GiB weights (either wasting VRAM or risking overcommit) — you'd need
   to hand-tune a separate byte value per profile, redoing this whole sweep
   each time. A percentage doesn't have that problem.
2. **It keeps vLLM's own safety profiling.** Confirmed via vLLM's own log
   output when `kv_cache_memory_bytes` is set: *"reserved 4.5 GiB memory for
   KV Cache as specified by kv_cache_memory_bytes config and **skipped
   memory profiling**. This does not respect the gpu_memory_utilization
   config."* — i.e. the explicit-bytes path bypasses the profiling step that
   normally protects against OOM from activation-memory spikes. That's a
   real tradeoff, not a free upgrade.

`KV_CACHE_MEMORY_BYTES` is still wired up in both model profiles (empty by
default) if you want it for a specific, deliberate reason — e.g. pinning an
exact, predictable KV cache size across model swaps rather than
recalculating a percentage each time.

## Case study: context length was raised from 16K to 32K live

The 30B profile started at a conservative `MAX_MODEL_LEN=16384`. A real
OpenCode "build" agent session hit it live on `scar.lab`: normal multi-turn
coding work (file contents, tool output, accumulated conversation) fills
16K faster than it looks like it should, and once input + the reserved
output budget crossed 16384 tokens, the session failed outright on every
retry —

```
AI_APICallError: This model's maximum context length is 16384 tokens.
However, you requested 4096 output tokens and your prompt contains at
least 12289 input tokens, for a total of at least 16385 tokens.
```

This is the baseline → change → measure → keep process in action, just
triggered by real usage instead of a deliberate experiment. Fix: raised
`MAX_MODEL_LEN` to 32768, restarted, re-measured. Verified live: KV cache
dropped to 4.51 GiB / 49,248 tokens (~1.5x concurrency at the new, larger
context — down from ~3.1x at 16K, as expected, since KV cache scales with
context length), but real total VRAM used barely moved (~23.9 GiB either
way) — the `GPU_MEMORY_UTILIZATION=0.68` choice held up unchanged. Also had
to re-run `scripts/configure-opencode.sh` afterward: it derives
`limit.context`/`limit.output` from the profile's `MAX_MODEL_LEN`, so an
existing OpenCode config still points at the old ceiling until refreshed —
this doesn't happen automatically on a vLLM restart.

If 32K also proves insufficient for real sessions, the same process applies
again — go bigger, re-measure KV cache/VRAM, don't just assume it still
fits.

Two things worth understanding about this setting, so it doesn't get
over-trusted:

1. **It's a cap on vLLM's own allocation, not a guarantee of desktop
   headroom.** `--gpu-memory-utilization` tells vLLM "you may use up to this
   fraction of total device memory for weights + KV cache + activations." It
   does not coordinate with anything else using the GPU. In practice 0.68
   leaves a large enough margin that pressure is unlikely, but "unlikely"
   isn't "impossible" — `scripts/workstation-benchmark.sh` exists precisely
   to check this against real desktop load rather than assume it, and did
   confirm it live (browser + IDE + active inference simultaneously, VRAM
   free held stable at ~7.5 GiB throughout).
2. **Model weights and KV cache are the two things actually consuming that
   budget**, and they behave differently: weights are a fixed cost set by
   the model/quantization choice; KV cache is reserved as a fixed-size pool
   at startup (sized from context length × the memory budget) and does
   *not* grow further during inference — confirmed live: VRAM used was
   identical whether vLLM was idle or serving concurrent requests. A
   profile that "fits" at low concurrency can still hit a KV-cache-capacity
   ceiling at higher concurrency (requests start queuing, not the desktop
   losing VRAM) — this is exactly what `scripts/benchmark.sh` at increasing
   `--concurrency` is for.

If you need to reclaim more VRAM for the desktop, lower
`GPU_MEMORY_UTILIZATION` in the relevant `config/models/*.env` file — see
the sweep table above for what to expect. If you're confident the desktop
load is light and want more room for KV cache/concurrency, raise it — but
do that deliberately and re-benchmark, not reflexively.

## The process for any tuning change

```
baseline
   ↓
change ONE variable
   ↓
scripts/benchmark.sh <profile> --concurrency N --prompt-tokens N
   ↓
(for VRAM/desktop-impact changes: scripts/workstation-benchmark.sh too)
   ↓
compare against the previous benchmarks/results/*.json
   ↓
keep or revert
```

`EXTRA_VLLM_ARGS` is not empty by default — both profiles set
`--enable-auto-tool-choice --tool-call-parser <qwen3_xml|hermes>` because
that's a functional requirement for agentic tools like OpenCode (see
docs/OPENCODE.md), not a performance experiment. Everything below is a
different category: *optional, unproven* performance/behavior tuning,
each a candidate for *deliberate, measured* experimentation, not a
recommended default.

## Candidate tuning areas (not enabled by default)

- **FP8 quantization** — blocked on confirming gfx1201 FP8 kernel support
  actually works (rather than silently falling back to FP32 dequant) in the
  pinned image. See docs/MODELS.md's quantization table. If/when confirmed
  fixed, FP8 could roughly halve the 30B model's weight footprint vs AWQ's
  INT4 — worth revisiting, but only with a real correctness+performance
  check, not an assumption.
- **FP8 KV cache** (`KV_CACHE_DTYPE=fp8`) — same gfx1201-kernel-maturity
  caveat as FP8 weights applies to the KV cache path. Could meaningfully
  extend usable context/concurrency within the VRAM budget if it works
  correctly.
- **AITER kernels** (`VLLM_ROCM_USE_AITER=1`) — AMD's own Day-0 guidance for
  R9700 enables this, and community reports tie it to fixing long-context
  performance issues on gfx1201. Not enabled by default here because it
  wasn't validated against the specific image/vLLM version this repo pins —
  add it to a profile's `EXTRA_VLLM_ARGS`... actually this is a container
  *environment* variable, not a `vllm serve` flag, so it belongs in the
  profile's env file directly (it'll be picked up via `env_file` like any
  other variable) — add `VLLM_ROCM_USE_AITER=1` as a new line, then
  benchmark against baseline.
- **Attention backend** — vLLM supports multiple attention backend
  implementations; which one is fastest/most correct on gfx1201 specifically
  is exactly the kind of thing that needs a real benchmark on this hardware,
  not a guess from documentation.
- **Context length beyond 32K** — the 30B profile is at 32K now (raised
  live from 16K; see the case study above), still below the model's
  advertised maximum. If real sessions outgrow 32K too, same process:
  change `MAX_MODEL_LEN`, benchmark, watch KV cache capacity shrink as
  context grows, re-run `scripts/configure-opencode.sh` afterward.
- **`--enforce-eager`** — disables HIP graph capture. Sometimes used as a
  troubleshooting step (if graph capture itself is the source of a crash or
  startup failure) or a latency/throughput tradeoff experiment. Not a
  default.
- Batching/scheduler configuration, GPU memory utilization itself,
  concurrency limits — all standard vLLM knobs, all worth the same
  baseline → change one thing → benchmark → compare cycle.

## What NOT to do

Don't stack multiple untested changes into one profile and call it "tuned."
If three flags are enabled and throughput improved, you don't know which
flag did it or whether one of the others is quietly hurting quality/latency.
One variable per benchmark run.
