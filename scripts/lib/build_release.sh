#!/usr/bin/env bash
# Shared frozen-input release build steps. Sourced by build-android and build-ios.

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
  source_commit="$(json_get "$SPEC" '.sourceCommit')"
  orion_commit="$(read_orion_commit "$SPEC")"
  if [[ ! -d "${WORKSPACE}/.git" ]]; then
    log "workspace is not a git checkout; run checkout-source in prepare"
    exit 1
  fi
  APP_DIR="$(resolve_release_app_dir "$WORKSPACE" "$source_commit" "$orion_commit")"
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

generate_frozen_release() {
  local gen_dir="$1"
  mkdir -p "$gen_dir"
  (cd "$APP_DIR" && "$RUNALL_DART" run tool/generate_release_build.dart "$SPEC" "$gen_dir")
  [[ -f "$gen_dir/dart-defines.json" && -f "$gen_dir/bundled.json" && -f "$gen_dir/platform-profiles.json" ]] || {
    log "Orion generate_release_build.dart did not write frozen outputs"
    exit 1
  }
  mkdir -p "${APP_DIR}/assets/releases"
  cp "$gen_dir/bundled.json" "${APP_DIR}/assets/releases/bundled.json"
  python3 - "$gen_dir/dart-defines.json" "$gen_dir/platform-profiles.json" "$SPEC" <<'PY'
import json, sys
from pathlib import Path
defines = json.loads(Path(sys.argv[1]).read_text())
profiles = json.loads(Path(sys.argv[2]).read_text())
spec = json.loads(Path(sys.argv[3]).read_text())
app = spec["config"]["app"]
env = spec["config"]["environment"]
platform = spec["platform"]
required = {
    "APP_ENV": env["name"],
    "MERCURY_BASE_URL": env["mercuryBaseUrl"],
    "RUNTIME_BASE_URL": env["runtimeBaseUrl"],
    "RUNTIME_APP_BINDING": str(spec["appId"]),
    "RELEASE_CHANNEL": env["releaseChannel"],
}
for key, value in required.items():
    if defines.get(key) != value:
        raise SystemExit(f"frozen dart define mismatch: {key}")
profile = profiles.get(platform) or {}
identifier = app["applicationId"] if platform == "android" else app["bundleId"]
if profile.get("applicationIdentifier") != identifier:
    raise SystemExit("frozen platform profile identifier mismatch")
if profile.get("targets") != spec["targets"]:
    raise SystemExit("frozen platform profile targets mismatch")
PY
}
