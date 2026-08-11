#!/usr/bin/env bash
# Shared helpers for scripts/*.sh. Not meant to be executed directly.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Repo root, regardless of caller's cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

MODEL_PROFILE_DIR="${REPO_ROOT}/config/models"

# Repo-wide default profile when none is given on the command line. Override
# per-invocation with an explicit profile argument, or permanently via
# DEFAULT_MODEL_PROFILE in .env.
DEFAULT_MODEL_PROFILE_FALLBACK="qwen3-coder-30b-a3b"
export DEFAULT_MODEL_PROFILE_FALLBACK

# Short, memorable names that map to the actual config/models/*.env
# filenames, so e.g. `start.sh qwen3-coder` works without typing the full
# `qwen3-coder-30b-a3b` profile name.
resolve_profile_alias() {
  case "$1" in
    qwen3-coder) echo "qwen3-coder-30b-a3b" ;;
    qwen25-coder|qwen2.5-coder) echo "qwen25-coder-14b" ;;
    *) echo "$1" ;;
  esac
}

# --- output helpers ---------------------------------------------------------

if [[ -t 1 ]]; then
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_BLUE=$'\033[34m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_RED=""; COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_RESET=""
fi

log_info()  { printf '%s\n' "$*" >&2; }
log_pass()  { printf '%s[PASS]%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; }
log_fail()  { printf '%s[FAIL]%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*"; }
log_step()  { printf '%s==>%s %s\n' "${COLOR_BLUE}" "${COLOR_RESET}" "$*" >&2; }

# --- .env loading ------------------------------------------------------------

# Loads .env into the current shell (export). Does not fail if .env is
# missing — callers that require it should check for themselves.
load_env() {
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
  fi
}

require_env_file() {
  if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    log_fail ".env not found. Run: cp .env.example .env"
    exit 1
  fi
}

# --- model profiles ----------------------------------------------------------

list_model_profiles() {
  local f
  for f in "${MODEL_PROFILE_DIR}"/*.env; do
    [[ -e "$f" ]] || continue
    basename "$f" .env
  done
}

# Prints the resolved path to a profile's env file, or fails with a helpful
# message listing valid profiles.
resolve_model_profile() {
  local profile
  profile="$(resolve_profile_alias "$1")"
  local path="${MODEL_PROFILE_DIR}/${profile}.env"
  if [[ -z "$profile" ]]; then
    log_fail "No model profile given."
    log_info "Available profiles:"
    list_model_profiles | sed 's/^/  - /' >&2
    exit 1
  fi
  if [[ ! -f "$path" ]]; then
    log_fail "Unknown model profile: '${profile}'"
    log_info "Available profiles:"
    list_model_profiles | sed 's/^/  - /' >&2
    exit 1
  fi
  printf '%s\n' "$path"
}

# --- current-profile state ---------------------------------------------------

# docker compose needs MODEL_PROFILE set (to resolve config/models/*.env via
# env_file) for every subcommand, not just up — including down/ps/logs. We
# remember the last profile start.sh used so stop.sh/status.sh don't require
# the caller to repeat it.
CURRENT_PROFILE_FILE="${REPO_ROOT}/.vllm-profile"

save_current_profile() {
  printf '%s\n' "$1" > "$CURRENT_PROFILE_FILE"
}

# Prints the remembered profile, or empty if none.
load_current_profile() {
  [[ -f "$CURRENT_PROFILE_FILE" ]] && cat "$CURRENT_PROFILE_FILE"
  return 0
}

# --- docker compose -----------------------------------------------------------

# Echoes the compose command to use ("docker compose" or "docker-compose").
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    log_fail "Neither 'docker compose' nor 'docker-compose' is available."
    exit 1
  fi
}

# Runs docker compose in the repo root with MODEL_PROFILE exported, so
# env_file: config/models/${MODEL_PROFILE}.env resolves correctly.
compose() {
  local cmd
  cmd="$(compose_cmd)"
  (cd "${REPO_ROOT}" && MODEL_PROFILE="${MODEL_PROFILE:-}" $cmd "$@")
}

# --- misc ---------------------------------------------------------------------

api_base_url() {
  load_env
  local host="${API_BIND_ADDRESS:-127.0.0.1}"
  # 0.0.0.0 isn't dereferenceable from the client side; use localhost instead.
  [[ "$host" == "0.0.0.0" ]] && host="localhost"
  printf 'http://%s:%s\n' "$host" "${API_PORT:-8000}"
}
