#!/usr/bin/env bash
# Shared frozen-input native build steps. Sourced by build-android and build-ios.

absolute_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  printf '%s\n' "$(pwd)/$path"
}

prepare_frozen_workspace() {
  local spec="$1" workspace="$2"
  SPEC="$(absolute_path "$spec")"
  WORKSPACE="$(cd "$workspace" && pwd)"
  validate_build_spec_document "$SPEC"
  source_commit="$(read_source_ref "$SPEC")"
  orion_commit="$(read_orion_commit "$SPEC")"
  if [[ ! -d "${WORKSPACE}/.git" ]]; then
    log "workspace is not a git checkout; run checkout-source in prepare"
    exit 1
  fi
  APP_DIR="$(resolve_release_app_dir "$WORKSPACE" "$source_commit" "$orion_commit")"
  verify_lock_digest_if_present "$SPEC" "$WORKSPACE"
  local env_file
  env_file="$(mktemp)"
  "${RUNALL_ROOT}/scripts/ensure-flutter" --spec "$SPEC" --workspace "$WORKSPACE" --env-file "$env_file"
  # shellcheck disable=SC1090
  source "$env_file"
  [[ -x "$RUNALL_FLUTTER" && -x "$RUNALL_DART" ]] || {
    log "flutter toolchain was not resolved"
    exit 1
  }
}

materialize_frozen_resources() {
  local spec="$1" dest="$2"
  run_dart_tool materialize "$spec" "$dest" "${RUNALL_FROZEN_RESOURCE_ROOT:-}" "${RUNALL_RESOURCE_INDEX:-}"
}

apply_release_overlay() {
  local overlay="$1" app_dir="$2"
  [[ -d "$overlay" ]] || {
    log "Orion release overlay is missing"
    exit 1
  }
  run_dart_tool overlay "$overlay" "$app_dir"
}

generate_frozen_release() {
  local gen_dir="$1" scratch index settings_env
  scratch="$(dirname "$gen_dir")"
  if [[ -e "$gen_dir" || -e "${scratch}/resources" ]]; then
    log "native build output already exists"
    exit 1
  fi
  mkdir -p "${scratch}/resources"
  materialize_frozen_resources "$SPEC" "${scratch}/resources"
  index="${scratch}/resources/resources.json"
  (cd "${WORKSPACE}/tools/rigel_build" && "$RUNALL_DART" pub get --enforce-lockfile)
  "$RUNALL_DART" run "${WORKSPACE}/tools/rigel_build/bin/assemble.dart" "$SPEC" "$gen_dir" "$index"
  [[ -f "$gen_dir/dart-defines.json" && -f "$gen_dir/build-settings.json" ]] || {
    log "Orion app assembler did not write frozen outputs"
    exit 1
  }
  apply_release_overlay "$gen_dir/overlay" "$APP_DIR"
  settings_env="${scratch}/settings.env"
  run_dart_tool settings "$gen_dir/dart-defines.json" "$gen_dir/build-settings.json" "$SPEC" "$settings_env"
  # Values were checked against the frozen spec before quoting.
  # shellcheck disable=SC1090
  source "$settings_env"
}
