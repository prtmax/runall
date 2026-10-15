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

compute_spec_hash() {
  local spec_file="$1"
  local common_dir
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  require_cmd python3
  python3 "${common_dir}/spec_hash.py" "$spec_file" | tr -d '\n'
}

verify_spec_hash_field() {
  local spec_file="$1"
  local declared computed
  declared="$(json_get "$spec_file" '.specHash')"
  computed="$(compute_spec_hash "$spec_file")"
  if [[ "$declared" != "$computed" ]]; then
    log "specHash does not match canonical document digest"
    exit 1
  fi
}

verify_declared_resource_digests() {
  local spec_file="$1"
  require_cmd jq
  local count root
  count="$(jq -r '.resources // [] | length' "$spec_file")"
  if [[ "$count" == "0" ]]; then
    return 0
  fi
  root="${RUNALL_RESOURCE_ROOT:-$(dirname "$spec_file")}"
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    local path digest
    path="$(jq -r ".resources[$i].path // empty" "$spec_file")"
    digest="$(jq -r ".resources[$i].sha256 // empty" "$spec_file")"
    if [[ -z "$path" || -z "$digest" ]]; then
      log "resource entry missing path or sha256"
      exit 1
    fi
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      log "invalid resource digest: $path"
      exit 1
    fi
    if [[ "$path" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
      log "resource path must be a relative file, not a URL: $path"
      exit 1
    fi
    if [[ "$path" == /* || "$path" == *".."* ]]; then
      log "resource path rejected: $path"
      exit 1
    fi
    local file_path="${root%/}/$path"
    if [[ ! -f "$file_path" ]]; then
      log "resource file missing: $path"
      exit 1
    fi
    local actual="sha256:$(sha256_file "$file_path")"
    if [[ "$actual" != "$digest" ]]; then
      log "resource digest mismatch: $path"
      exit 1
    fi
    i=$((i + 1))
  done
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

  verify_spec_hash_field "$spec_file"
  verify_declared_resource_digests "$spec_file"
}
