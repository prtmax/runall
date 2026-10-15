#!/usr/bin/env bash
# Shared helpers for runall executor scripts. No secrets are logged.
set -euo pipefail

log() {
  printf '[runall] %s\n' "$*" >&2
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || {
    log "missing required command: $c"
    exit 1
  }
}

json_get() {
  local file="$1" expr="$2"
  jq -r "$expr" "$file"
}

assert_non_empty() {
  local name="$1" value="$2"
  if [[ -z "${value// }" ]]; then
    log "required value empty: $name"
    exit 1
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

validate_build_spec_document() {
  local spec_file="$1" expected_run_id="${2:-}"

  require_cmd jq
  jq -e '.specHash | startswith("sha256:")' "$spec_file" >/dev/null
  jq -r '.repository' "$spec_file" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  jq -r '.sourceCommit' "$spec_file" | grep -Eq '^[0-9a-f]{40}$'
  jq -r '.platform' "$spec_file" | grep -Eq '^(android|ios)$'

  local platform
  platform="$(json_get "$spec_file" '.platform')"
  if [[ "$platform" == "android" ]]; then
    jq -e '(.targets | length) > 0 and all(.targets[]; . == "apk" or . == "aab")' "$spec_file" >/dev/null
  else
    jq -e '.targets == ["ipa"]' "$spec_file" >/dev/null
  fi

  if [[ -n "$expected_run_id" ]]; then
    local rid
    rid="$(json_get "$spec_file" '.buildRunId // empty')"
    if [[ -n "$rid" && "$rid" != "$expected_run_id" ]]; then
      log "build spec buildRunId mismatch"
      exit 1
    fi
  fi
}
