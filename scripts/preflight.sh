#!/usr/bin/env bash
# Validates the host is ready to run vLLM on ROCm before we try to start it.
# Read-only: never installs, modifies, or writes anything outside /tmp.
#
# Usage: scripts/preflight.sh
set -uo pipefail # not -e: individual checks must not abort the whole run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

EXPECTED_GFX="gfx1201"
FAIL_COUNT=0
WARN_COUNT=0

pass() { log_pass "$*"; }
warn() { log_warn "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { log_fail "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

section() { printf '\n%s\n' "$*"; }

# --- OS ----------------------------------------------------------------------

section "Operating system"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    pass "Ubuntu detected (${PRETTY_NAME:-unknown version})"
  else
    warn "Not Ubuntu (detected: ${PRETTY_NAME:-${ID:-unknown}}) — this project targets Ubuntu; other distros are untested"
  fi
else
  warn "/etc/os-release not found — could not determine distro"
fi

# --- Docker --------------------------------------------------------------

section "Docker"
if command -v docker >/dev/null 2>&1; then
  ver="$(docker --version 2>/dev/null || true)"
  pass "Docker installed (${ver})"
  if docker info >/dev/null 2>&1; then
    pass "Docker daemon is reachable"
  else
    fail "Docker daemon is not reachable (is it running? is your user in the 'docker' group?)"
  fi
else
  fail "Docker is not installed or not on PATH"
fi

if docker compose version >/dev/null 2>&1; then
  pass "Docker Compose plugin available ($(docker compose version --short 2>/dev/null))"
elif command -v docker-compose >/dev/null 2>&1; then
  warn "Using standalone docker-compose ($(docker-compose --version 2>/dev/null)); the 'docker compose' plugin is preferred"
else
  fail "Neither 'docker compose' (plugin) nor 'docker-compose' (standalone) is available"
fi

# --- GPU device nodes ------------------------------------------------------

section "GPU device nodes"
if [[ -e /dev/kfd ]]; then
  pass "/dev/kfd present"
else
  fail "/dev/kfd not present — amdgpu/ROCm kernel driver does not appear to be loaded"
fi

if [[ -e /dev/dri ]]; then
  render_nodes=$(find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$render_nodes" -gt 0 ]]; then
    pass "/dev/dri present with ${render_nodes} render node(s)"
  else
    warn "/dev/dri present but no renderD* nodes found"
  fi
else
  fail "/dev/dri not present"
fi

# Docker access permissions to the GPU device nodes.
section "Device permissions"
for dev in /dev/kfd /dev/dri; do
  [[ -e "$dev" ]] || continue
  owner_group="$(stat -c '%U:%G' "$dev" 2>/dev/null || echo 'unknown')"
  pass "${dev} owned by ${owner_group}"
done

if getent group video >/dev/null 2>&1; then
  video_gid="$(getent group video | cut -d: -f3)"
  pass "'video' group exists (gid ${video_gid})"
  if id -nG "${USER}" 2>/dev/null | grep -qw video; then
    pass "Current user (${USER}) is in the 'video' group"
  else
    warn "Current user (${USER}) is NOT in the 'video' group — may not be required for the container (device access is enforced by the container's own group_add), but is worth checking if things don't work"
  fi
else
  warn "'video' group does not exist on this host"
fi

if getent group render >/dev/null 2>&1; then
  render_gid="$(getent group render | cut -d: -f3)"
  pass "'render' group exists (gid ${render_gid})"
  log_info "  If compose.yaml's default group_add (video, render by name) doesn't grant container access, set RENDER_GID=${render_gid} in .env"
else
  warn "'render' group does not exist on this host — set RENDER_GID explicitly in .env if the container can't access /dev/dri"
fi

# --- ROCm userspace tools ----------------------------------------------------

section "ROCm userspace tools"
detected_gfx=""

if command -v rocminfo >/dev/null 2>&1; then
  pass "rocminfo found"
  rocminfo_out="$(rocminfo 2>/dev/null || true)"
  if [[ -n "$rocminfo_out" ]]; then
    detected_gfx="$(printf '%s\n' "$rocminfo_out" | grep -m1 -oE 'gfx[0-9a-fA-F]+' || true)"
    if [[ -n "$detected_gfx" ]]; then
      if [[ "$detected_gfx" == "$EXPECTED_GFX" ]]; then
        pass "Detected GPU architecture: ${detected_gfx} (matches expected ${EXPECTED_GFX})"
      else
        warn "Detected GPU architecture: ${detected_gfx} (expected ${EXPECTED_GFX} for Radeon AI PRO R9700) — profiles/images in this repo are tuned for gfx1201"
      fi
    else
      warn "rocminfo ran but no gfx architecture string was found in its output"
    fi
  else
    warn "rocminfo produced no output"
  fi
else
  warn "rocminfo not found on host — this only affects host-side diagnostics; the container brings its own ROCm userspace. Install via the ROCm APT repo if you want host-side checks (see docs/ROCM.md)."
fi

if command -v rocm-smi >/dev/null 2>&1; then
  pass "rocm-smi found"
  if rocm_smi_out="$(rocm-smi --showmeminfo vram 2>/dev/null)"; then
    pass "rocm-smi VRAM query succeeded"
    printf '%s\n' "$rocm_smi_out" | sed 's/^/  /'
  else
    warn "rocm-smi found but VRAM query failed (permissions? driver mismatch?)"
  fi
else
  warn "rocm-smi not found on host — same caveat as rocminfo above"
fi

# --- Disk space --------------------------------------------------------------

section "Disk space"
load_env
hf_cache_dir="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
check_path="$hf_cache_dir"
[[ -d "$check_path" ]] || check_path="$(dirname "$check_path")"
if [[ -d "$check_path" ]]; then
  avail_kb="$(df -Pk "$check_path" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "${avail_kb:-}" ]]; then
    avail_gb=$((avail_kb / 1024 / 1024))
    if [[ "$avail_gb" -lt 30 ]]; then
      warn "Only ${avail_gb} GiB free at ${check_path} — a single coding model can be 8-30+ GiB; downloading more than one will need more"
    else
      pass "${avail_gb} GiB free at ${check_path}"
    fi
  else
    warn "Could not determine free space at ${check_path}"
  fi
else
  warn "Neither HF_CACHE_DIR nor its parent exists yet (${hf_cache_dir}) — it will be created on first run"
fi

# --- Required directories / HF cache -----------------------------------------

section "Hugging Face cache"
if [[ -z "${HF_CACHE_DIR:-}" ]]; then
  warn "HF_CACHE_DIR not set (.env missing or not sourced) — defaulting to ${hf_cache_dir}"
else
  pass "HF_CACHE_DIR=${HF_CACHE_DIR}"
fi
if [[ -d "$hf_cache_dir" ]]; then
  pass "HF cache directory exists: ${hf_cache_dir}"
else
  warn "HF cache directory does not exist yet: ${hf_cache_dir} (Docker will create it on first run, owned by root — see docs/ROCM.md if that causes permission issues)"
fi

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  warn ".env not found — run: cp .env.example .env"
fi

# --- Summary -------------------------------------------------------------

section "Summary"
echo "Failures: ${FAIL_COUNT}  Warnings: ${WARN_COUNT}"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  log_fail "Preflight found blocking issues. Resolve FAIL items above before starting vLLM."
  exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  log_warn "Preflight passed with warnings. Review them above."
  exit 0
else
  log_pass "Preflight passed."
  exit 0
fi
