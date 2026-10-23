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

source_origin_url() {
  local repository="$1" slug=""
  if [[ "$repository" == "prtmax/orion" ]]; then
    slug="prtmax/orion"
  elif [[ "$repository" =~ ^https://github\.com/prtmax/orion(\.git)?$ ]]; then
    slug="prtmax/orion"
  else
    log "build source repository is not the trusted prtmax/orion authority"
    exit 1
  fi
  printf 'https://github.com/%s.git' "$slug"
}

read_orion_commit() {
  local file="$1" commit
  require_cmd jq
  commit="$(jq -r '.buildInput.source.commit // empty' "$file")"
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ || "$commit" =~ ^0+$ ]]; then
    log "buildInput.source.commit must be an exact Git commit"
    exit 1
  fi
  printf '%s' "$commit"
}

# Print the Flutter app directory for a checked-out source tree.
resolve_release_app_dir() {
  local workspace="$1" source_commit="$2" orion_commit="$3" head
  head="$(git -C "$workspace" rev-parse HEAD)"
  if [[ "$head" != "$source_commit" ]]; then
    log "workspace source commit mismatch"
    exit 1
  fi
  if [[ -f "$workspace/tools/app_assembler/assemble.py" ]]; then
    if [[ "$source_commit" != "$orion_commit" ]]; then
      log "direct Orion checkout must match buildInput.source.commit"
      exit 1
    fi
    printf '%s\n' "$workspace/apps/rigel"
    return 0
  fi
  log "source is not an Orion checkout with the native app assembler"
  exit 1
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
  require_cmd node
  node "${common_dir}/native_digest.js" spec "$spec_file" | tr -d '\n'
}

verify_spec_hash_field() {
  local spec_file="$1"
  local declared computed
  declared="$(json_get "$spec_file" '.specDigest')"
  computed="$(compute_spec_hash "$spec_file")"
  if [[ "$declared" != "$computed" ]]; then
    log "specDigest does not match immutable native build facts"
    exit 1
  fi
}

validate_build_spec_document() {
  local spec_file="$1" expected_run_id="${2:-}"

  require_cmd jq
  jq -e '.schemaVersion == "cosmos.native-build.v1" or .schemaVersion == "cosmos.native-build.v2"' "$spec_file" >/dev/null
  jq -e '.status == "ready"' "$spec_file" >/dev/null
  jq -r '.specDigest' "$spec_file" | grep -Eq '^[0-9a-f]{64}$'
  jq -r '.inputDigest' "$spec_file" | grep -Eq '^[0-9a-f]{64}$'
  jq -e '.buildInput.schemaVersion == .schemaVersion' "$spec_file" >/dev/null
  jq -e '
    if .schemaVersion == "cosmos.native-build.v1" then
      (.buildInput | has("appearance") | not)
    else
      .buildInput.appearance as $appearance |
      $appearance.version == "app-appearance.v1" and
      ($appearance.styles | type == "array" and length > 0) and
      ($appearance.defaultStyleKey | type == "string" and length > 0) and
      ([$appearance.styles[].styleKey] | length == (unique | length)) and
      any($appearance.styles[]; .styleKey == $appearance.defaultStyleKey) and
      all($appearance.styles[];
        . as $style |
        (.styleKey | type == "string" and length > 0) and
        (.features | type == "array" and length > 0) and
        (.themes | type == "array" and length > 0) and
        (.defaultThemeRef | type == "string" and length > 0) and
        any($style.themes[]; .themeRef == $style.defaultThemeRef))
    end
  ' "$spec_file" >/dev/null
  jq -e '.buildInput.source.flutterVersion | type == "string" and length > 0' "$spec_file" >/dev/null
  source_origin_url "$(json_get "$spec_file" '.buildInput.source.repository')" >/dev/null
  jq -r '.buildInput.source.commit' "$spec_file" | grep -Eq '^[0-9a-f]{40}$'
  jq -r '.buildInput.source.lockDigest' "$spec_file" | grep -Eq '^[0-9a-f]{64}$'
  jq -e '.tenantId == .buildInput.tenantId and .appId == .buildInput.appId and .catalogId == .buildInput.source.catalogId' "$spec_file" >/dev/null
  read_orion_commit "$spec_file" >/dev/null
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
  local common_dir input_digest
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  input_digest="$(node "${common_dir}/native_digest.js" input "$spec_file" | tr -d '\n')"
  [[ "$input_digest" == "$(json_get "$spec_file" '.inputDigest')" ]] || {
    log "inputDigest does not match buildInput"
    exit 1
  }
}

normalize_sha256() {
  local raw="${1#sha256:}"
  raw="${raw//:/}"
  raw="${raw// /}"
  raw="${raw,,}"
  if [[ ! "$raw" =~ ^[0-9a-f]{64}$ ]]; then
    log "value is not a SHA-256 digest"
    exit 1
  fi
  printf '%s' "$raw"
}

# Frozen specs store the package version on buildInput.app, and versionCode is a
# JSON number. A string, null, or config.ios copy is not a signing input.
read_app_version_code() {
  local file="$1" code
  require_cmd jq
  if ! code="$(jq -er 'if (.buildInput.app.versionCode|type)=="number" then .buildInput.app.versionCode else empty end' "$file")"; then
    log "buildInput.app.versionCode must be a JSON number"
    exit 1
  fi
  if [[ ! "$code" =~ ^[0-9]+$ ]]; then
    log "buildInput.app.versionCode must be an integer"
    exit 1
  fi
  printf '%s' "$code"
}

require_sign_receipt_fields() {
  local package_name="$1" version_name="$2" version_code="$3" cert="$4"
  assert_non_empty "sign package" "$package_name"
  assert_non_empty "sign versionName" "$version_name"
  if [[ ! "$version_code" =~ ^[0-9]+$ ]]; then
    log "refusing sign receipt without an integer versionCode"
    exit 1
  fi
  normalize_sha256 "$cert" >/dev/null
}

# A signed file without an accepted receipt is not a successful output.
discard_unreported_output() {
  local reported="$1" output="$2" input="${3:-}"
  if [[ "$reported" == 1 || -z "$output" || ! -f "$output" ]]; then
    return 0
  fi
  if [[ -n "$input" && "$output" == "$input" ]]; then
    log "refusing to remove signed output that aliases the input"
    return 0
  fi
  rm -f -- "$output"
}

# Record the signed file with the sign-stage credential. Finalize upload is
# authorized only when this exact size and digest were stored.
report_sign_result() {
  local target="$1" package_name="$2" version_name="$3" version_code="$4" cert="$5" artifact="$6"
  require_sign_receipt_fields "$package_name" "$version_name" "$version_code" "$cert"
  assert_non_empty "COSMOS_BUILD_CALLBACK_URL" "${COSMOS_BUILD_CALLBACK_URL:-}"
  assert_non_empty "COSMOS_BUILD_CREDENTIAL" "${COSMOS_BUILD_CREDENTIAL:-}"
  assert_non_empty "BUILD_RUN_ID" "${BUILD_RUN_ID:-}"
  [[ -f "$artifact" ]] || { log "signed artifact missing"; exit 1; }
  local cert_hex size digest
  cert_hex="$(normalize_sha256 "$cert")"
  size="$(wc -c <"$artifact" | tr -d ' ')"
  digest="$(sha256_file "$artifact")"
  require_cmd curl
  require_cmd jq
  curl --fail-with-body -sS -X POST \
    -H "Authorization: Bearer ${COSMOS_BUILD_CREDENTIAL}" \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -n \
      --arg target "$target" \
      --arg packageName "$package_name" \
      --arg versionName "$version_name" \
      --argjson versionCode "$version_code" \
      --arg certSha256 "$cert_hex" \
      --argjson byteSize "$size" \
      --arg sha256 "$digest" \
      '{target: $target, packageName: $packageName, versionName: $versionName, versionCode: $versionCode, certSha256: $certSha256, byteSize: $byteSize, sha256: $sha256}')" \
    "${COSMOS_BUILD_CALLBACK_URL%/}/build-runs/${BUILD_RUN_ID}/sign-results" >/dev/null
}
