#!/usr/bin/env bash
# Installs/updates this repo's behavioral rules into OpenCode's global
# AGENTS.md and installs the compaction recovery plugin (CLI and Desktop
# share these files — see docs/OPENCODE.md).
#
# This is called by scripts/configure-opencode.sh as part of full setup,
# or can be run standalone to manage rules/plugins independently.
#
# The repo's config/opencode/AGENTS.md is copied into a clearly delimited,
# idempotent managed block inside the global file, so any unrelated rules
# the user already has there are preserved untouched.
# The compaction recovery plugin is installed to <config_dir>/plugins/
# to customize compaction summaries around operational state.
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
REPO_PLUGIN="${REPO_ROOT}/config/opencode/plugins/compaction-recovery.js"
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
  --force     Reinstall rules and plugins even if already up to date.
  --status    Report whether installed rules/plugins match the repo (no changes).
  --diff      Show diff between repo rules/plugins and installed files.
  --remove    Delete the managed rules block and compaction plugin (backs up first).
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

if [[ -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
  CONFIG_DIR="$OPENCODE_CONFIG_DIR"
elif command -v opencode >/dev/null 2>&1; then
  CONFIG_DIR="$(opencode debug paths 2>/dev/null | awk '$1=="config"{print $2}')"
fi
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/opencode}"
GLOBAL_RULES="${CONFIG_DIR}/AGENTS.md"
PLUGINS_DIR="${CONFIG_DIR}/plugins"
GLOBAL_PLUGIN="${PLUGINS_DIR}/compaction-recovery.js"

# --- helpers ---------------------------------------------------------------

require_repo_rules() {
  if [[ ! -f "$REPO_RULES" ]]; then
    log_fail "Repo rules file not found: ${REPO_RULES}"
    exit 1
  fi
}

require_repo_plugin() {
  if [[ ! -f "$REPO_PLUGIN" ]]; then
    log_fail "Repo plugin file not found: ${REPO_PLUGIN}"
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

backup_file() {
  local target="$1"
  local backup
  backup="${target}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$target" "$backup"
  printf '%s\n' "$backup"
}

# --- --status ----------------------------------------------------------------

if [[ "$MODE" == "status" ]]; then
  require_repo_rules
  require_repo_plugin
  log_info "Repo rules:   ${REPO_RULES}"
  log_info "Global rules: ${GLOBAL_RULES}"
  log_info "Repo plugin:  ${REPO_PLUGIN}"
  log_info "Global plugin:${GLOBAL_PLUGIN}"

  rules_ok=1
  plugin_ok=1

  if [[ ! -f "$GLOBAL_RULES" ]]; then
    log_warn "Global rules file does not exist — not installed."
    rules_ok=0
  else
    begin_count="$(count_marker_occurrences "$BEGIN_MARKER")"
    if [[ "$begin_count" -eq 0 ]]; then
      log_warn "Managed block not present in ${GLOBAL_RULES} — not installed."
      rules_ok=0
    elif [[ "$begin_count" -gt 1 ]]; then
      log_fail "Found ${begin_count} managed block markers (expected 1) — file needs manual review."
      rules_ok=0
    else
      desired="$(build_managed_block)"
      installed="$(extract_managed_block)"
      if [[ "$desired" == "$installed" ]]; then
        log_pass "Installed rules match the repo — up to date."
      else
        log_warn "Installed rules differ from the repo."
        rules_ok=0
      fi
    fi
  fi

  if [[ ! -f "$GLOBAL_PLUGIN" ]]; then
    log_warn "Compaction recovery plugin does not exist at ${GLOBAL_PLUGIN} — not installed."
    plugin_ok=0
  else
    if cmp -s "$REPO_PLUGIN" "$GLOBAL_PLUGIN"; then
      log_pass "Installed compaction recovery plugin matches repo — up to date."
    else
      log_warn "Installed compaction recovery plugin differs from repo."
      plugin_ok=0
    fi
  fi

  if [[ "$rules_ok" -eq 1 && "$plugin_ok" -eq 1 ]]; then
    exit 0
  else
    log_warn "Configuration out of sync — run without flags to update, or --diff to see changes."
    exit 1
  fi
fi

# --- --diff --------------------------------------------------------------

if [[ "$MODE" == "diff" ]]; then
  require_repo_rules
  require_repo_plugin

  log_step "Diffing rules:"
  desired_file="$(mktemp)"
  installed_file="$(mktemp)"
  trap 'rm -f "$desired_file" "$installed_file"' EXIT
  build_managed_block > "$desired_file"
  extract_managed_block > "$installed_file"
  if diff -u "$installed_file" "$desired_file" --label "installed (${GLOBAL_RULES})" --label "repo (${REPO_RULES})"; then
    log_pass "Rules: No differences."
  fi

  log_step "Diffing compaction plugin:"
  if [[ -f "$GLOBAL_PLUGIN" ]]; then
    if diff -u "$GLOBAL_PLUGIN" "$REPO_PLUGIN" --label "installed (${GLOBAL_PLUGIN})" --label "repo (${REPO_PLUGIN})"; then
      log_pass "Plugin: No differences."
    fi
  else
    log_info "Plugin not yet installed at ${GLOBAL_PLUGIN}."
  fi
  exit 0
fi

# --- --remove --------------------------------------------------------------

if [[ "$MODE" == "remove" ]]; then
  # 1. Remove rules block
  if [[ -f "$GLOBAL_RULES" ]]; then
    begin_count="$(count_marker_occurrences "$BEGIN_MARKER")"
    if [[ "$begin_count" -gt 0 ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_step "Dry run — would remove the managed block from ${GLOBAL_RULES} (backup first)."
      else
        backup="$(backup_file "$GLOBAL_RULES")"
        tmp="$(mktemp)"
        awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
          $0 == b { inblock=1; next }
          $0 == e { inblock=0; next }
          !inblock { print }
        ' "$GLOBAL_RULES" > "$tmp"
        awk 'BEGIN{blank=0} /^[[:space:]]*$/{blank++; if(blank<=1) print; next} {blank=0; print}' "$tmp" > "${tmp}.trimmed"
        mv "${tmp}.trimmed" "$GLOBAL_RULES"
        rm -f "$tmp"
        log_pass "Removed managed block from ${GLOBAL_RULES} (backup: ${backup})"
      fi
    else
      log_warn "Managed block not present in ${GLOBAL_RULES}."
    fi
  else
    log_warn "No global rules file at ${GLOBAL_RULES}."
  fi

  # 2. Remove plugin
  if [[ -f "$GLOBAL_PLUGIN" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_step "Dry run — would remove ${GLOBAL_PLUGIN} (backup first)."
    else
      backup="$(backup_file "$GLOBAL_PLUGIN")"
      rm -f "$GLOBAL_PLUGIN"
      log_pass "Removed compaction recovery plugin ${GLOBAL_PLUGIN} (backup: ${backup})"
    fi
  else
    log_warn "No plugin installed at ${GLOBAL_PLUGIN}."
  fi
  exit 0
fi

# --- install/update (default mode) ------------------------------------------

require_repo_rules
require_repo_plugin

# 1. Check rules
begin_count="$(count_marker_occurrences "$BEGIN_MARKER")"
if [[ "$begin_count" -gt 1 ]]; then
  log_fail "Found ${begin_count} managed block markers in ${GLOBAL_RULES} (expected 0 or 1)."
  log_info "This file needs manual cleanup before this script can safely manage it."
  exit 1
fi

desired="$(build_managed_block)"
installed="$(extract_managed_block)"
rules_need_update=1
if [[ "$begin_count" -eq 1 && "$desired" == "$installed" && "$FORCE" -eq 0 ]]; then
  rules_need_update=0
fi

# 2. Check plugin
plugin_need_update=1
if [[ -f "$GLOBAL_PLUGIN" && "$FORCE" -eq 0 ]] && cmp -s "$REPO_PLUGIN" "$GLOBAL_PLUGIN"; then
  plugin_need_update=0
fi

if [[ "$rules_need_update" -eq 0 && "$plugin_need_update" -eq 0 ]]; then
  log_pass "Global rules and compaction plugin already up to date: ${CONFIG_DIR}"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$rules_need_update" -eq 1 ]]; then
    log_step "Dry run — would write the following managed block to ${GLOBAL_RULES}:"
    printf '%s\n' "$desired"
  fi
  if [[ "$plugin_need_update" -eq 1 ]]; then
    log_step "Dry run — would copy ${REPO_PLUGIN} to ${GLOBAL_PLUGIN}"
  fi
  exit 0
fi

mkdir -p "$CONFIG_DIR" "$PLUGINS_DIR"

# Install/update rules
if [[ "$rules_need_update" -eq 1 ]]; then
  if [[ -f "$GLOBAL_RULES" ]]; then
    backup="$(backup_file "$GLOBAL_RULES")"
    log_info "Backed up existing global rules: ${backup}"
  else
    backup=""
    : > "$GLOBAL_RULES"
  fi

  tmp="$(mktemp)"
  if [[ "$begin_count" -eq 1 ]]; then
    block_file="$(mktemp)"
    printf '%s\n' "$desired" > "$block_file"
    awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" -v blockfile="$block_file" '
      $0 == b { while ((getline line < blockfile) > 0) print line; inblock=1; next }
      $0 == e { inblock=0; next }
      !inblock { print }
    ' "$GLOBAL_RULES" > "$tmp"
    rm -f "$block_file"
  else
    cp "$GLOBAL_RULES" "$tmp"
    if [[ -s "$tmp" ]]; then
      printf '\n' >> "$tmp"
    fi
    build_managed_block >> "$tmp"
  fi
  mv "$tmp" "$GLOBAL_RULES"
  log_pass "Installed behavioral rules to ${GLOBAL_RULES}"
  [[ -n "$backup" ]] && log_info "Rules backup: ${backup}"
fi

# Install/update compaction recovery plugin
if [[ "$plugin_need_update" -eq 1 ]]; then
  if [[ -f "$GLOBAL_PLUGIN" ]]; then
    pbackup="$(backup_file "$GLOBAL_PLUGIN")"
    log_info "Backed up existing plugin: ${pbackup}"
  fi
  cp "$REPO_PLUGIN" "$GLOBAL_PLUGIN"
  log_pass "Installed compaction recovery plugin to ${GLOBAL_PLUGIN}"
fi

log_info "Applies to OpenCode CLI and Desktop (shared config dir: ${CONFIG_DIR})."
log_info "Verify: ${SCRIPT_DIR}/$(basename "$0") --status"
