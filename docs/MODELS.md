# Model profiles

Profiles live in `config/models/*.env` and are selected by filename (without
the extension): `scripts/start.sh <profile-name>`. Each profile is
self-contained — Hugging Face model ID, served name, context length, GPU
memory utilization, quantization, KV cache dtype, and any extra `vllm serve`
flags.

## Quantization: what's actually usable on gfx1201 right now

This mattered enough to shape both profiles below, so it's worth stating the
reasoning once instead of repeating it per-model.

| Format | Status on gfx1201 (mid-2026) | Used here? |
|---|---|---|
| **BF16** (unquantized) | Works, but doubles the memory footprint of every other option below — see the VRAM math in each profile file. Doesn't fit either model inside the workstation budget. | No |
| **FP8** | AMD advertises FP8-capable hardware, but native FP8 WMMA kernel support for gfx1201 specifically has been reported as missing from vLLM's ROCm architecture table as of ROCm ~7.2–7.14 — meaning FP8 weights can silently dequantize to FP32 instead of using the fast path, unless community kernel patches are applied. Community upstreaming of a gfx1201 FP8 patch was still in progress as of this writing. Independent of that risk, FP8's ~1 byte/param footprint doesn't fit the 30B model in this repo's VRAM budget anyway (see below). | No (baseline). Worth revisiting once upstream support lands — see docs/TUNING.md. |
| **AWQ (INT4)** | vLLM has an AWQ kernel path that isn't tied to NVIDIA's Marlin kernels, so it's expected to work on ROCm — but explicitly request `--quantization awq`, not the auto-detected `awq_marlin`, which *is* Marlin/CUDA-only. This is what both profiles use. | **Yes** |
| **GPTQ** | Similar story to AWQ; a viable alternative, not used here only because AWQ builds were more readily available for both target models. | Not used, but a reasonable substitute |
| **GGUF** | vLLM's own GGUF loader is documented upstream as an experimental, limited path (e.g. no tensor parallelism, generally lower throughput than native formats) independent of ROCm — this is a vLLM-wide caveat, not gfx1201-specific. llama.cpp is the more mature GGUF runtime, but that's a different serving stack than what this repo deploys. | No |
| **BitsAndBytes** | AMD support is inconsistent across architectures and, as far as could be confirmed, not established for gfx1201. | No |

This table was originally written from documentation and issue trackers, not
direct testing. It has since been spot-checked live on `scar.lab` (see
per-model notes below) — AWQ is confirmed working for both profiles. FP8,
GGUF, and BitsAndBytes remain unverified hypotheses; re-check before relying
on them.

**Live-verified gotcha, not obvious from documentation:** "AWQ" is not one
container format. The 14B profile's checkpoint (official Qwen) uses the
legacy AWQ config, where forcing `--quantization awq` matters (avoids
vLLM auto-selecting the CUDA-only `awq_marlin`). The 30B profile's
checkpoint (community, via `llm-compressor`) is packaged in the newer
**compressed-tensors** format instead — forcing `--quantization awq` on it
fails hard at startup with a config mismatch error. Fixed by leaving
`QUANTIZATION` empty in that profile so vLLM reads the method the
checkpoint itself declares. **Check the actual checkpoint's `config.json`
`quantization_config.quant_method` before assuming which handling a new
AWQ-labeled model needs** — "AWQ" in a model name doesn't tell you which
container format it's in.

## Qwen3-Coder-30B-A3B-Instruct

Config: `config/models/qwen3-coder-30b-a3b.env`

This is a Mixture-of-Experts model: 30B total parameters, ~3.3B active per
token. **The active-parameter count describes compute cost per token, not
memory footprint** — serving it requires every expert's weights resident in
VRAM, so its memory behavior is that of a 30B model, not a 3.3B one.

VRAM math (see also the profile file's inline comments):

- BF16: ~60 GB — impossible on a 32 GB card regardless of budget.
- FP8/INT8: ~30 GB weights alone, leaving effectively nothing for KV cache
  inside the ~22-24 GB budget this repo targets (see docs/TUNING.md).
- **AWQ INT4** (chosen): ~17-18 GB weights, leaving headroom for KV cache at
  the 16K baseline context.

`MODEL_ID` defaults to `stelterlab/Qwen3-Coder-30B-A3B-Instruct-AWQ`, a
**third-party** quantization (built via the standard `llm-compressor`
toolchain, not published by Qwen or AMD). Its accuracy has not been
independently verified here. Alternatives if you want to compare:

- `QuantTrio/Qwen3-Coder-30B-A3B-Instruct-AWQ` — reported elsewhere as
  showing more quality loss under 4-bit quantization than the stelterlab build.
- `QuantTrio/Qwen3-Coder-30B-A3B-Instruct-GPTQ-Int8` — INT8, better quality,
  but back to the ~30 GB footprint problem above; would need a smaller
  context and/or a larger VRAM budget to fit.
- `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` — the official Qwen FP8 build;
  revisit once gfx1201 FP8 kernel support is confirmed working, and only
  with a relaxed VRAM budget or reduced context.

**Context:** baseline is 16K (`MAX_MODEL_LEN=16384`), deliberately far below
the model's advertised maximum. The task plan calls for evaluating 8K/16K/32K
— do that via `scripts/benchmark.sh` once 16K is confirmed working, changing
one variable at a time (see docs/TUNING.md).

**This is the repo's default profile** (`DEFAULT_MODEL_PROFILE` in `.env`) —
`scripts/start.sh` with no arguments starts this. **Verified live on
`scar.lab`:** starts cleanly (once `QUANTIZATION` was left unset — see the
compressed-tensors note above), weights load at 15.74 GiB. `GPU_MEMORY_UTILIZATION`
was tuned from 0.72 down to **0.68** via a live sweep — see docs/TUNING.md
for the full comparison table; at 0.68, KV cache gets 4.6 GiB (~50K tokens,
~3.1x concurrency headroom at 16K context), real total VRAM used is
**~23.9 GiB**, leaving **~7.7-8 GiB** for the desktop. A quick single-stream
benchmark (512-token prompt, 128 max tokens) measured **~43 tok/s** —
notably faster than the 14B dense model's ~10 tok/s in the same test,
consistent with the ~3.3B active-parameter compute cost per token despite
the larger total weight footprint. `scripts/workstation-benchmark.sh`
additionally confirmed this holds with a real browser + IDE + concurrent
inference all running at once (docs/BENCHMARKING.md). Also verified: tool
calling (required for OpenCode — see docs/OPENCODE.md) via
`--tool-call-parser qwen3_xml`, and real coding-agent usage through OpenCode
CLI (file read/write via real tool calls, both succeeded). Take the
throughput numbers as one data point each, not a characterized baseline —
re-run `scripts/benchmark.sh` across the concurrency/prompt-size matrix
before drawing further conclusions.

## Qwen2.5-Coder-14B-Instruct

Config: `config/models/qwen25-coder-14b.env`

Dense (non-MoE) 14B model — used here as the lower-memory comparison/control
against the 30B MoE model. Its memory footprint is exactly what it looks
like, no active-vs-total-parameter subtlety.

`MODEL_ID` is `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ` — an **officially
published** Qwen quantization, not a third-party build, which makes this the
lower-risk profile of the two.

VRAM math: AWQ INT4 weights are ~8-9 GB, comfortably inside the ~23 GB
budget and leaving substantially more headroom than the 30B profile — for
KV cache, concurrency, or a longer context (baseline here is 32K, still
within the model's native, non-YaRN context window).

Use this profile to sanity-check the deployment (smaller download, faster
load, lower risk of VRAM pressure) before trying the 30B profile, and as the
throughput/quality baseline the 30B model gets compared against.

**Verified live on `scar.lab`:** starts cleanly with `QUANTIZATION=awq`
(this checkpoint's legacy AWQ config needs that override — see above).
Weights load at 9.38 GiB, KV cache gets 11.36 GiB — 20.7 GiB total, inside
the ~22.9 GiB budget (`GPU_MEMORY_UTILIZATION=0.72` here, unchanged — this
profile wasn't part of the tuning sweep since it already has generous
headroom; see docs/TUNING.md). A quick single-stream benchmark (512-token
prompt, 128 max tokens) measured ~10 tok/s. Tool calling enabled via
`--tool-call-parser hermes` (required for OpenCode — see docs/OPENCODE.md),
not yet separately re-verified with a live OpenCode session the way the 30B
profile was.

## Adding a new profile

Copy an existing `config/models/*.env` file, change `MODEL_ID` /
`SERVED_MODEL_NAME` / context / quantization as needed, and do the VRAM math
in a comment the way the existing profiles do — `params × bytes-per-param`
against the ~23 GB budget, before assuming it'll fit. Run
`scripts/start.sh <new-profile-name>`.
