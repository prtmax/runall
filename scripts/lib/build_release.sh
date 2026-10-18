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

materialize_frozen_resources() {
  local spec="$1" dest="$2"
  python3 - "$spec" "$dest" "${RUNALL_FROZEN_RESOURCE_ROOT:-}" "${RUNALL_RESOURCE_INDEX:-}" <<'PY'
import hashlib, json, sys
from pathlib import Path

spec_path = Path(sys.argv[1])
dest = Path(sys.argv[2])
root_arg, index_arg = sys.argv[3], sys.argv[4]
spec = json.loads(spec_path.read_text(encoding="utf-8"))
config = spec["config"]

def load_index():
    if index_arg:
        path = Path(index_arg)
        if not path.is_file():
            raise SystemExit("RUNALL_RESOURCE_INDEX is missing")
        return path
    root = Path(root_arg) if root_arg else spec_path.parent / "frozen-resources"
    path = root / "index.json"
    if not path.is_file():
        raise SystemExit("frozen resource index is missing")
    return path

def reject_path(value):
    if not isinstance(value, str) or value == "" or value.startswith("/") or "://" in value or "\\" in value:
        raise SystemExit("resource index path must be a relative file")
    parts = Path(value).parts
    if any(part in {"", ".", ".."} for part in parts):
        raise SystemExit("resource index path rejected")

source_index = load_index()
try:
    mapping = json.loads(source_index.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    raise SystemExit("resource index is not JSON") from exc
if not isinstance(mapping, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in mapping.items()):
    raise SystemExit("resource index must map frozen refs to local paths")

required = {}
for field in ("brandAssets", "languages"):
    rows = config.get(field)
    if not isinstance(rows, list) or not rows:
        raise SystemExit(f"config.{field} is missing")
    for row in rows:
        ref, digest = row.get("ref"), row.get("digest")
        if not isinstance(ref, str) or not isinstance(digest, str):
            raise SystemExit(f"config.{field} ref is invalid")
        if ref in required and required[ref] != digest:
            raise SystemExit("frozen ref digest conflict")
        required[ref] = digest
if set(mapping) != set(required):
    raise SystemExit("resource index refs do not match the frozen spec")

staged = {}
for ref, digest in required.items():
    reject_path(mapping[ref])
    file_path = source_index.parent.joinpath(mapping[ref]).resolve()
    root = source_index.parent.resolve()
    if root != file_path and root not in file_path.parents:
        raise SystemExit("resource file escapes the index directory")
    if not file_path.is_file() or file_path.is_symlink():
        raise SystemExit(f"frozen resource file missing: {ref}")
    data = file_path.read_bytes()
    actual = "sha256:" + hashlib.sha256(data).hexdigest()
    if actual != digest:
        raise SystemExit(f"frozen resource digest mismatch: {ref}")
    name = hashlib.sha256(ref.encode("utf-8")).hexdigest()
    target = dest / name
    target.write_bytes(data)
    staged[ref] = name
(dest / "resources.json").write_text(json.dumps(staged, sort_keys=True) + "\n", encoding="utf-8")
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
  rm -rf "$gen_dir" "${scratch}/resources"
  mkdir -p "$gen_dir" "${scratch}/resources"
  materialize_frozen_resources "$SPEC" "${scratch}/resources"
  index="${scratch}/resources/resources.json"
  (cd "$APP_DIR" && "$RUNALL_DART" run tool/generate_release_build.dart "$SPEC" "$gen_dir" "$index")
  [[ -f "$gen_dir/dart-defines.json" && -f "$gen_dir/bundled.json" && -f "$gen_dir/platform-profiles.json" && -f "$gen_dir/build-settings.json" ]] || {
    log "Orion generate_release_build.dart did not write frozen outputs"
    exit 1
  }
  if ! cmp -s "$gen_dir/bundled.json" "$gen_dir/overlay/assets/releases/bundled.json"; then
    log "overlay bundled Release does not match generator output"
    exit 1
  fi
  apply_release_overlay "$gen_dir/overlay" "$APP_DIR"
  settings_env="${scratch}/settings.env"
  python3 - "$gen_dir/dart-defines.json" "$gen_dir/platform-profiles.json" "$gen_dir/build-settings.json" "$SPEC" "$settings_env" <<'PY'
import json, shlex, sys
from pathlib import Path
defines = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
profiles = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
settings = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
spec = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
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
Path(sys.argv[5]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  # Values were checked against the frozen spec before quoting.
  # shellcheck disable=SC1090
  source "$settings_env"
}
