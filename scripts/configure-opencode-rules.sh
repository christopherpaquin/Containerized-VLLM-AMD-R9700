#!/usr/bin/env bash
# Installs/updates this repo's behavioral rules into OpenCode's global
# AGENTS.md (CLI and Desktop share this file — see docs/OPENCODE.md).
#
# This is deliberately separate from scripts/configure-opencode.sh, which
# owns provider/model wiring. This script owns behavioral instructions only.
# Actual tool authorization is OpenCode's own permission system
# (`permission` in opencode.json(c)) — rules here are guidance, not
# enforcement.
#
# The repo's config/opencode/AGENTS.md is copied into a clearly delimited,
# idempotent managed block inside the global file, so any unrelated rules
# the user already has there are preserved untouched.
#
# Usage:
#   scripts/configure-opencode-rules.sh [--dry-run] [--force]
#   scripts/configure-opencode-rules.sh --status
#   scripts/configure-opencode-rules.sh --diff
#   scripts/configure-opencode-rules.sh --remove
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_RULES="${REPO_ROOT}/config/opencode/AGENTS.md"
BEGIN_MARKER="<!-- BEGIN SCAR-VLLM MANAGED RULES -->"
END_MARKER="<!-- END SCAR-VLLM MANAGED RULES -->"

DRY_RUN=0
FORCE=0
MODE="install"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--dry-run] [--force]
       $(basename "$0") --status
       $(basename "$0") --diff
       $(basename "$0") --remove

  --dry-run   Print what would change; touch nothing.
  --force     Reinstall the managed block even if already up to date.
  --status    Report whether installed rules match the repo (no changes).
  --diff      Show a diff between repo rules and the installed managed block.
  --remove    Delete only the managed block (backs up first).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --status) MODE="status"; shift ;;
    --diff) MODE="diff"; shift ;;
    --remove) MODE="remove"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_fail "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# --- locate the global OpenCode config dir --------------------------------

if command -v opencode >/dev/null 2>&1; then
  CONFIG_DIR="$(opencode debug paths 2>/dev/null | awk '$1=="config"{print $2}')"
fi
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/opencode}"
GLOBAL_RULES="${CONFIG_DIR}/AGENTS.md"

# --- helpers ---------------------------------------------------------------

require_repo_rules() {
  if [[ ! -f "$REPO_RULES" ]]; then
    log_fail "Repo rules file not found: ${REPO_RULES}"
    exit 1
  fi
}

# Builds the managed block (markers + repo rules content) into stdout.
build_managed_block() {
  printf '%s\n' "$BEGIN_MARKER"
  printf '%s\n' "# scar-vllm: managed by scripts/configure-opencode-rules.sh — do not edit by hand"
  printf '%s\n' "# Source of truth: config/opencode/AGENTS.md in the Containerized-VLLM-AMD-R9700 repo."
  printf '\n'
  cat "$REPO_RULES"
  printf '\n'
  printf '%s\n' "$END_MARKER"
}

# Extracts the current managed block content from the global file (between
# markers, inclusive), or nothing if absent/file missing.
extract_managed_block() {
  [[ -f "$GLOBAL_RULES" ]] || return 0
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    $0 == b { inblock=1 }
    inblock { print }
    $0 == e { inblock=0 }
  ' "$GLOBAL_RULES"
}

count_marker_occurrences() {
  local marker="$1"
  [[ -f "$GLOBAL_RULES" ]] || { echo 0; return; }
  grep -Fc "$marker" "$GLOBAL_RULES" || true
}

backup_global_rules() {
  local backup
  backup="${GLOBAL_RULES}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$GLOBAL_RULES" "$backup"
  printf '%s\n' "$backup"
}

# --- --status ----------------------------------------------------------------

if [[ "$MODE" == "status" ]]; then
  require_repo_rules
  log_info "Repo rules:   ${REPO_RULES}"
  log_info "Global rules: ${GLOBAL_RULES}"

  if [[ ! -f "$GLOBAL_RULES" ]]; then
    log_warn "Global rules file does not exist — not installed."
    exit 1
  fi

  begin_count="$(count_marker_occurrences "$BEGIN_MARKER")"
  if [[ "$begin_count" -eq 0 ]]; then
    log_warn "Managed block not present in ${GLOBAL_RULES} — not installed."
    exit 1
  elif [[ "$begin_count" -gt 1 ]]; then
    log_fail "Found ${begin_count} managed block markers (expected 1) — file needs manual review."
    exit 1
  fi

  desired="$(build_managed_block)"
  installed="$(extract_managed_block)"
  if [[ "$desired" == "$installed" ]]; then
    log_pass "Installed rules match the repo — up to date."
    exit 0
  else
    log_warn "Installed rules differ from the repo — run without flags to update, or --diff to see changes."
    exit 1
  fi
fi

# --- --diff --------------------------------------------------------------

if [[ "$MODE" == "diff" ]]; then
  require_repo_rules
  desired_file="$(mktemp)"
  installed_file="$(mktemp)"
  trap 'rm -f "$desired_file" "$installed_file"' EXIT
  build_managed_block > "$desired_file"
  extract_managed_block > "$installed_file"
  if diff -u "$installed_file" "$desired_file" --label "installed (${GLOBAL_RULES})" --label "repo (${REPO_RULES})"; then
    log_pass "No differences."
  fi
  exit 0
fi

# --- --remove --------------------------------------------------------------

if [[ "$MODE" == "remove" ]]; then
  if [[ ! -f "$GLOBAL_RULES" ]]; then
    log_warn "No global rules file at ${GLOBAL_RULES} — nothing to remove."
    exit 0
  fi
  begin_count="$(count_marker_occurrences "$BEGIN_MARKER")"
  if [[ "$begin_count" -eq 0 ]]; then
    log_warn "Managed block not present in ${GLOBAL_RULES} — nothing to remove."
    exit 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_step "Dry run — would remove the managed block from ${GLOBAL_RULES} (backup first)."
    exit 0
  fi

  backup="$(backup_global_rules)"
  tmp="$(mktemp)"
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    $0 == b { inblock=1; next }
    $0 == e { inblock=0; next }
    !inblock { print }
  ' "$GLOBAL_RULES" > "$tmp"
  # Collapse runs of >1 blank line left behind where the block used to be.
  awk 'BEGIN{blank=0} /^[[:space:]]*$/{blank++; if(blank<=1) print; next} {blank=0; print}' "$tmp" > "${tmp}.trimmed"
  mv "${tmp}.trimmed" "$GLOBAL_RULES"
  rm -f "$tmp"
  log_pass "Removed managed block from ${GLOBAL_RULES} (backup: ${backup})"
  exit 0
fi

# --- install/update (default mode) ------------------------------------------

require_repo_rules

begin_count="$(count_marker_occurrences "$BEGIN_MARKER")"
if [[ "$begin_count" -gt 1 ]]; then
  log_fail "Found ${begin_count} managed block markers in ${GLOBAL_RULES} (expected 0 or 1)."
  log_info "This file needs manual cleanup before this script can safely manage it."
  exit 1
fi

desired="$(build_managed_block)"
installed="$(extract_managed_block)"

if [[ "$begin_count" -eq 1 && "$desired" == "$installed" && "$FORCE" -eq 0 ]]; then
  log_pass "Global rules already up to date: ${GLOBAL_RULES}"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_step "Dry run — would write the following managed block to ${GLOBAL_RULES}:"
  printf '%s\n' "$desired"
  if [[ "$begin_count" -eq 0 ]]; then
    log_info "(file does not currently have a managed block — would be appended)"
  fi
  exit 0
fi

mkdir -p "$CONFIG_DIR"

if [[ -f "$GLOBAL_RULES" ]]; then
  backup="$(backup_global_rules)"
  log_info "Backed up existing global rules: ${backup}"
else
  backup=""
  : > "$GLOBAL_RULES"
fi

tmp="$(mktemp)"
if [[ "$begin_count" -eq 1 ]]; then
  # Replace the existing block in place. The new block is read from a file
  # (not an awk -v string) so its content is never subject to awk's
  # backslash-escape interpretation.
  block_file="$(mktemp)"
  printf '%s\n' "$desired" > "$block_file"
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" -v blockfile="$block_file" '
    $0 == b { while ((getline line < blockfile) > 0) print line; inblock=1; next }
    $0 == e { inblock=0; next }
    !inblock { print }
  ' "$GLOBAL_RULES" > "$tmp"
  rm -f "$block_file"
else
  # Append: preserve existing content, add exactly one blank-line separator.
  cp "$GLOBAL_RULES" "$tmp"
  if [[ -s "$tmp" ]]; then
    printf '\n' >> "$tmp"
  fi
  build_managed_block >> "$tmp"
fi
mv "$tmp" "$GLOBAL_RULES"

log_pass "Installed behavioral rules to ${GLOBAL_RULES}"
[[ -n "$backup" ]] && log_info "Backup: ${backup}"
log_info "Applies to OpenCode CLI and Desktop (shared config dir: ${CONFIG_DIR})."
log_info "Verify: ${SCRIPT_DIR}/$(basename "$0") --status"
