# ROCm on the Radeon AI PRO R9700 (gfx1201)

This document covers the ROCm-specific decisions in this repo: which
container image, why, what the device passthrough is doing, and known risks
specific to this GPU generation.

## Hardware context

The Radeon AI PRO R9700 is an RDNA4 workstation GPU, architecture `gfx1201`,
with 32 GB of VRAM. RDNA4 is new enough (first ROCm support landed in 2025)
that vLLM/ROCm compatibility is actively evolving — this is *not* a mature,
long-settled combination like CDNA (MI-series) + vLLM. Expect rough edges
and verify everything on `scar.lab` directly; don't assume anything below
still holds without checking current versions.

## Container image

**Selected:** `rocm/vllm:rocm7.14.0_rdna_ubuntu24.04_py3.14_pytorch_2.11.0_vllm_0.23.0`

This is AMD's official, pinned ROCm/vLLM image for RDNA GPUs. AMD's ROCm AI
ecosystem docs list gfx1201 (Radeon AI PRO R9700/R9700S, RX 9070 series)
under the GPUs this image family supports.

Two alternatives were considered and rejected as the *default* (but are
worth knowing about if the primary image misbehaves on this specific card):

- **`rocm/vllm:rocm7.13.0_gfx120X-all_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1`**
  — an architecture-scoped build (gfx120X specifically, rather than the
  general RDNA umbrella) on an older, more field-tested ROCm/vLLM
  combination. If the `rdna` image fails to detect/run on gfx1201 correctly,
  try this one — narrower architecture targeting sometimes means better
  tuned kernels for exactly this GPU, at the cost of an older vLLM.
- **`rocm/vllm-dev:open-r9700-08052025`** — a one-off image AMD published
  for R9700 Day-0 support of OpenAI's gpt-oss models. Not used as the
  default because it's a `-dev` snapshot tied to a specific launch, not a
  generally-maintained tag — but it's evidence AMD has validated *some*
  image against this exact GPU, so it's a reasonable thing to try if both
  images above have problems.

To switch images, set `VLLM_IMAGE` in `.env` — no compose.yaml edit needed.

**Known issue to watch for:** vLLM versions 0.21.0–0.25.0 have a documented
"significantly longer warmup time" issue on Radeon GPUs, reportedly fixed in
0.26.0+. The pinned image here uses vLLM 0.23.0. This should mean slow
startup, not failure — but if `scripts/start.sh` times out waiting for
health, this is one of the first things to check (increase the wait, or try
a newer image tag).

**Known container-startup risk (RDNA4 specifically):** vLLM's platform
detection on gfx1201 has been reported to fail inside containers in some
configurations — `amdsmi` can't initialize (it needs sysfs/hwmon paths that
may not be exposed the same way in a container), which can cascade into a
circular-import crash or `torch.cuda.device_count()` returning 0. This was
reported against nightly ROCm/vLLM builds under k3s/podman. **Did not
reproduce** on `scar.lab` with plain `docker compose` and this repo's pinned
image — both model profiles started and served requests successfully. Worth
knowing about if you hit import errors or "no CUDA/HIP devices found"
despite the GPU being visible on the host, but not something this repo's
default setup currently triggers.

**Confirmed live on `scar.lab`:** the container's `group_add: [video, render]`
by name fails outright — `Error response from daemon: unable to find group
render: no matching entries in group file` — because this image's Ubuntu
base doesn't ship a `render` group in `/etc/group`. This is not a rare edge
case; expect to hit it. Fix: set `RENDER_GID` in `.env` to this host's actual
render GID (`getent group render` on the host, or read it from
`scripts/preflight.sh`'s output). `video` resolved fine by name in this
testing; if it doesn't on a different host, `VIDEO_GID` exists for the same
reason.

**Confirmed live on `scar.lab`:** cold-start timing for the 14B profile
(empty HF cache, empty torch.compile cache) was ~13 minutes — ~3 min weight
download + ~7 min loading weights into VRAM + ~1 min `torch.compile`/graph
capture. `compose.yaml`'s healthcheck `start_period` is set to 1200s (20 min)
to accommodate this plus margin for the 30B profile / a less-warmed cache.
Also confirmed: vLLM's `torch.compile` cache lives at `/root/.cache/vllm`
inside the container, which is a **separate mount** from the HF weights
cache (`/root/.cache/huggingface`) — `compose.yaml` persists both via
`HF_CACHE_DIR` and `VLLM_CACHE_DIR` respectively. Without the second mount,
every restart repeats the full compile step.

**Benign warnings you'll see in the logs, confirmed harmless:** `Unknown
vLLM environment variable detected: VLLM_IMAGE` / `VLLM_CACHE_DIR` — these
are Compose-level config variables that end up inside the container because
`env_file: .env` passes the whole file through, but vLLM itself doesn't
consume them. Not an error, nothing to fix.

## What the device passthrough is doing

`compose.yaml` grants the container exactly what ROCm needs and nothing more:

| Setting | Purpose |
|---|---|
| `devices: /dev/kfd, /dev/dri` | ROCm's kernel driver interfaces. Nothing else from `/dev` is mounted. |
| `group_add: video, render` | Container process joins these groups so it has permission to use the device nodes above (device ownership is normally `root:video` / `root:render` on the host). Override with `VIDEO_GID`/`RENDER_GID` in `.env` if the named groups don't exist or don't match inside the image — see `scripts/preflight.sh` output for this host's actual GIDs. |
| `security_opt: seccomp=unconfined` | Required by ROCm (AMD's own container examples set this); the default seccomp profile blocks syscalls ROCm's userspace needs. |
| `ipc: host` | ROCm/PyTorch inter-process shared memory. AMD's documented recommendation for vLLM on ROCm; using it means we don't also need to hand-tune `shm_size`. |

Notably absent, deliberately: `privileged: true`, the Docker socket, and any
host filesystem mount beyond the Hugging Face cache directory.

## Host-side ROCm tools (optional)

`scripts/preflight.sh` and `scripts/gpu-info.sh` use `rocminfo` / `rocm-smi`
*if present on the host* to sanity-check the GPU before/while the container
runs. They are not required — the container brings its own ROCm userspace —
but they're useful for independently confirming the driver/GPU is visible
outside any container. Install via AMD's ROCm APT repository if you want
them; this repo does not install them for you.

## Verified on `scar.lab`

Both model profiles have been started, health-checked, and benchmarked live
on the real R9700 — see the "Confirmed live" notes above and each profile's
notes in docs/MODELS.md for what was actually observed (VRAM numbers,
timing, the two real bugs that were found and fixed along the way). This
was real end-to-end validation, not just config-syntax checking — but it
was one run each, not a soak test. Re-verify after any change to
`compose.yaml`, a model profile, or the pinned image version:

```bash
scripts/preflight.sh
docker compose pull   # confirms the image tag actually exists/pulls
scripts/start.sh qwen25-coder-14b   # smaller model first — see docs/MODELS.md
```
