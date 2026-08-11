# Containerized vLLM — AMD Radeon AI PRO R9700

[![GPU](https://img.shields.io/badge/GPU-Radeon%20AI%20PRO%20R9700%20(gfx1201)-red)](docs/ROCM.md)
[![vLLM on ROCm](https://img.shields.io/badge/vLLM-ROCm-orange)](docs/ROCM.md)
[![License](https://img.shields.io/badge/license-unlicensed-lightgrey)](#)

Self-hosted, OpenAI-compatible coding-model inference on a single AMD
Radeon AI PRO R9700, via vLLM in Docker Compose — built for local
AI-assisted development, on a machine that's also a daily-use graphical
workstation.

## Target hardware

| | |
|---|---|
| Host | `scar.lab`, Ubuntu Linux |
| GPU | AMD Radeon AI PRO R9700 — 32 GB VRAM, architecture `gfx1201` |
| Also used for | Normal desktop/graphical work — vLLM must not consume all the GPU's memory |

## Prerequisites

- Docker and Docker Compose plugin
- The `amdgpu`/ROCm kernel driver loaded (`/dev/kfd`, `/dev/dri` present)
- Enough disk space for whichever model(s) you download (each is tens of GB)

Run `scripts/preflight.sh` to check all of this before starting anything —
see [Quick start](#quick-start).

## Quick start

```bash
cp .env.example .env    # then edit if needed (HF cache path, ports, ...)
scripts/preflight.sh    # validates the host before touching anything
scripts/start.sh        # starts the default model — Qwen3-Coder-30B-A3B
scripts/status.sh       # container/health/API/GPU state at a glance
scripts/configure-opencode.sh   # point OpenCode CLI + Desktop at it
scripts/configure-opencode-rules.sh   # install behavioral rules (AGENTS.md)
```

`start.sh` with no argument starts `DEFAULT_MODEL_PROFILE` (`.env`) — Qwen3-Coder
by default. Pass a profile explicitly to run something else:
`scripts/start.sh qwen25-coder-14b` (`qwen3-coder` and `qwen25-coder` also
work as short aliases). It runs preflight, starts the container, and waits
for the API to report healthy. First run can take **10+ minutes** (model
download + weight load into VRAM + one-time `torch.compile`) — this is
normal, not a hang; see docs/ROCM.md. If it fails immediately with `unable
to find group render`, set `RENDER_GID` in `.env` (`scripts/preflight.sh`
prints the value to use — this was needed on `scar.lab` itself, so expect to
need it).

Once healthy:

```bash
curl http://localhost:8000/v1/models

curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "qwen3-coder-30b-a3b", "messages": [{"role": "user", "content": "Say hi in one word."}]}'
```

## Model selection

```bash
scripts/start.sh                      # default: Qwen3-Coder-30B-A3B (see below)
scripts/start.sh qwen3-coder          # same, explicit (alias for qwen3-coder-30b-a3b)
scripts/start.sh qwen25-coder-14b     # dense 14B, official AWQ INT4 — lower memory, comparison baseline
```

Qwen3-Coder-30B-A3B (MoE, 3.3B active) is the default and primary target
model — best measured throughput (~43 tok/s single-stream vs. the 14B's ~10
tok/s) despite the larger total weight footprint. Profiles live in
`config/models/*.env` — Hugging Face model ID, context length, GPU memory
limit, quantization, tool-calling, and any extra flags, all without
touching `compose.yaml`. Why these two models, why AWQ instead of FP8, and
the VRAM math behind each: see **[docs/MODELS.md](docs/MODELS.md)**.

## Commands

| Command | Does |
|---|---|
| `scripts/preflight.sh` | Validates the host (Docker, GPU devices, ROCm tools, disk, permissions) without changing anything |
| `scripts/start.sh [profile]` | Preflight + start the selected (or default) model, waits for health |
| `scripts/stop.sh` | Stops the container (model cache and data are untouched) |
| `scripts/status.sh` | Container/health/model/API/GPU state at a glance — the primary post-login check |
| `scripts/healthcheck.sh [--full]` | `GET /v1/models`, optionally a real chat completion |
| `scripts/gpu-info.sh` | GPU/ROCm detail: arch, VRAM, utilization, clocks, temp, power |
| `scripts/benchmark.sh <profile> [...]` | One repeatable throughput/latency measurement — see [docs/BENCHMARKING.md](docs/BENCHMARKING.md) |
| `scripts/workstation-benchmark.sh` | Measures real VRAM headroom with the desktop actually in use — see [docs/BENCHMARKING.md](docs/BENCHMARKING.md) |
| `scripts/configure-opencode.sh` | Configures OpenCode CLI/Desktop to use this server — see [docs/OPENCODE.md](docs/OPENCODE.md) |
| `scripts/configure-opencode-rules.sh` | Installs/updates OpenCode's global behavioral rules (`~/.config/opencode/AGENTS.md`) — see [docs/OPENCODE.md](docs/OPENCODE.md) |

## API

OpenAI-compatible, served on **port 8000**, bound to `0.0.0.0` by default —
reachable from the LAN, not just `localhost` (see [Security](#security)
below). Configure via `API_PORT` / `API_BIND_ADDRESS` in `.env`.

## Workstation VRAM design philosophy

This machine stays a usable desktop while vLLM is running. The default
Qwen3-Coder profile caps vLLM at **`--gpu-memory-utilization 0.68`** —
tuned live on `scar.lab` by sweeping 0.72/0.68/0.65 and measuring *real*
total VRAM used (not the nominal percentage — actual usage runs a few GiB
over nominal due to graph-capture/allocator overhead). 0.68 lands at
**~23.9 GiB used, ~7.7-8 GiB free** for the desktop compositor, browser, and
IDE — confirmed with `scripts/workstation-benchmark.sh` under a real
Firefox + VS Code + active-inference load, where free VRAM stayed rock
stable at ~7.5 GiB throughout (vLLM's footprint is fixed once the KV cache
pool is reserved at startup — it doesn't grow further under load). A
dedicated inference server would typically push utilization to 0.90+;
that's deliberately not what this repo does. Full reasoning, the
alternative `--kv-cache-memory-bytes` mechanism and why it wasn't chosen as
the default: **[docs/TUNING.md](docs/TUNING.md)**.

## Security

- Not privileged; only `/dev/kfd` and `/dev/dri` are passed through — no
  other host devices, no Docker socket.
- API has **no authentication** — this is a LAN development tool, not a
  publicly-exposed service. Set `API_BIND_ADDRESS=127.0.0.1` in `.env` if
  you want to restrict it to this host only.
- No Hugging Face token is required for the default models; if you set
  `HUGGING_FACE_HUB_TOKEN` in `.env` for a gated model, it's read only from
  the gitignored `.env` file and never logged.

## Startup behavior

Meant to run as a persistent workstation service, not something you start
by hand each session. `compose.yaml` sets `restart: unless-stopped`, and
Docker itself (`docker.service`/`docker.socket`) is enabled at the systemd
level on `scar.lab` — so the sequence on boot is: systemd starts Docker →
Docker restarts every container that wasn't manually stopped, including
this one → vLLM reloads the model → the API becomes healthy again, all
without manual intervention. No separate systemd unit for this
repo — one restart-policy mechanism, not two competing ones.

Verified live (not just configured): restarting the Docker daemon itself
(`sudo systemctl restart docker`) — the closest safe proxy for a host
reboot without actually rebooting `scar.lab` out from under an active
session — brought the container back automatically, and it reached
`healthy` again on its own.

**Caveat:** this only holds if the container isn't left in a manually
stopped state. `scripts/stop.sh` stops it deliberately (e.g. to reclaim all
VRAM for a GPU-heavy desktop task) — Docker will *not* auto-restart it after
that until you run `scripts/start.sh` again, by design (that's what
"unless-stopped" means, as opposed to "always").

## Documentation

- **[docs/ROCM.md](docs/ROCM.md)** — container image choice, device
  passthrough details, known gfx1201-specific risks
- **[docs/MODELS.md](docs/MODELS.md)** — model profiles, VRAM math,
  quantization format decisions
- **[docs/TUNING.md](docs/TUNING.md)** — VRAM budget rationale, the
  baseline → change one thing → benchmark → compare process, candidate
  tuning knobs (none enabled by default)
- **[docs/BENCHMARKING.md](docs/BENCHMARKING.md)** — what `benchmark.sh`
  and `workstation-benchmark.sh` measure and how, current limitations
- **[docs/OPENCODE.md](docs/OPENCODE.md)** — configuring OpenCode CLI/Desktop
  against this server, why tool-calling needed enabling server-side

## Status

Both model profiles have been run end-to-end on the real R9700 on
`scar.lab`: started, health-checked, a real chat completion served,
benchmarked, and driven through OpenCode with real tool calls (file
read/write). Several real bugs were found and fixed in the process — a
Compose command that silently dropped every vLLM flag, a missing
`RENDER_GID`, a quantization-format mismatch, tool-calling not enabled
server-side, OpenCode's default `max_tokens` exceeding the context window
(see docs/ROCM.md, docs/MODELS.md, docs/OPENCODE.md) — which is why "looks
right in `docker compose config`" isn't the same as "works," and why the
docs call out what was actually verified versus still assumed.

Current running state (Qwen3-Coder-30B-A3B, default profile):

| | |
|---|---|
| Container image | `rocm/vllm:rocm7.14.0_rdna_ubuntu24.04_py3.14_pytorch_2.11.0_vllm_0.23.0` |
| VRAM used / free | ~24 GiB / ~7.7-8 GiB (`--gpu-memory-utilization 0.68`) |
| Single-stream throughput | ~43 tok/s, TTFT ~0.005-0.03s |
| Tool calling | Enabled (`qwen3_xml` parser) — required for OpenCode |
| OpenCode | CLI and Desktop both configured and verified working |
