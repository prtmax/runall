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
  source_commit="$(json_get "$SPEC" '.buildInput.source.commit')"
  orion_commit="$(read_orion_commit "$SPEC")"
  if [[ ! -d "${WORKSPACE}/.git" ]]; then
    log "workspace is not a git checkout; run checkout-source in prepare"
    exit 1
  fi
  APP_DIR="$(resolve_release_app_dir "$WORKSPACE" "$source_commit" "$orion_commit")"
  local expected_lock actual_lock
  expected_lock="$(json_get "$SPEC" '.buildInput.source.lockDigest')"
  actual_lock="$(sha256_file "${WORKSPACE}/pubspec.lock")"
  [[ "$expected_lock" == "$actual_lock" ]] || {
    log "Orion pubspec.lock digest mismatch"
    exit 1
  }
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
  python3 - "$spec" "$dest" "${RUNALL_FROZEN_RESOURCE_ROOT:-}" "${RUNALL_RESOURCE_INDEX:-}" "${RUNALL_ROOT}/scripts/lib" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[5])
from frozen_resources import materialize

materialize(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
PY
}

apply_release_overlay() {
  local overlay="$1" app_dir="$2"
  [[ -d "$overlay" ]] || {
    log "Orion release overlay is missing"
    exit 1
  }
  python3 - "$overlay" "$app_dir" <<'PY'
import os, sys
from pathlib import Path
overlay = Path(sys.argv[1]).resolve()
app = Path(sys.argv[2]).resolve()
found = False
for dirpath, dirnames, filenames in os.walk(overlay, followlinks=False):
    current = Path(dirpath)
    if current.is_symlink():
        raise SystemExit("overlay symlink rejected")
    dirnames[:] = [name for name in dirnames if not (current / name).is_symlink()]
    for name in filenames:
        src = current / name
        if src.is_symlink():
            raise SystemExit("overlay symlink rejected")
        rel = src.relative_to(overlay)
        if any(part in {"", ".", ".."} for part in rel.parts):
            raise SystemExit("overlay path rejected")
        dest = app.joinpath(rel)
        if dest.is_symlink() or any(parent.is_symlink() for parent in dest.parents if parent != app and app in parent.parents):
            raise SystemExit("overlay destination symlink rejected")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(src.read_bytes())
        found = True
if not found:
    raise SystemExit("release overlay is empty")
PY
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
  (cd "$APP_DIR" && python3 "${WORKSPACE}/tools/app_assembler/assemble.py" "$SPEC" "$gen_dir" "$index")
  [[ -f "$gen_dir/dart-defines.json" && -f "$gen_dir/build-settings.json" ]] || {
    log "Orion app assembler did not write frozen outputs"
    exit 1
  }
  apply_release_overlay "$gen_dir/overlay" "$APP_DIR"
  settings_env="${scratch}/settings.env"
  python3 - "$gen_dir/dart-defines.json" "$gen_dir/build-settings.json" "$SPEC" "$settings_env" <<'PY'
import json, shlex, sys
from pathlib import Path
defines = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
settings = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
spec = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
app = spec["buildInput"]["app"]
env = spec["buildInput"]["environment"]
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
expected = {
    "platform": platform,
    "applicationId": app["applicationId"],
    "bundleId": app["bundleId"],
    "displayName": app["displayName"],
    "versionName": app["versionName"],
    "versionCode": app["versionCode"],
}
for key, value in expected.items():
    if settings.get(key) != value:
        raise SystemExit(f"build-settings mismatch: {key}")
lines = [
    f"FROZEN_APPLICATION_ID={shlex.quote(str(settings['applicationId']))}",
    f"FROZEN_BUNDLE_ID={shlex.quote(str(settings['bundleId']))}",
    f"FROZEN_DISPLAY_NAME={shlex.quote(str(settings['displayName']))}",
    f"FROZEN_VERSION_NAME={shlex.quote(str(settings['versionName']))}",
    f"FROZEN_VERSION_CODE={shlex.quote(str(settings['versionCode']))}",
]
Path(sys.argv[4]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  # Values were checked against the frozen spec before quoting.
  # shellcheck disable=SC1090
  source "$settings_env"
}
