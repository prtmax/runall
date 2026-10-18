#!/usr/bin/env bash
# Offline cross-repo check. ORION_ROOT and COSMOS_ROOT must be the delivered checkouts.
# Runs the real Orion generator against a disposable clone, then the runall build
# scripts with a Flutter stub. Does not fetch resource URLs or sign artifacts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

assert_non_empty "ORION_ROOT" "${ORION_ROOT:-}"
assert_non_empty "COSMOS_ROOT" "${COSMOS_ROOT:-}"
[[ -f "${ORION_ROOT}/apps/rigel/tool/generate_release_build.dart" ]] || {
  log "ORION_ROOT is not an Orion checkout"
  exit 1
}
[[ -f "${COSMOS_ROOT}/solar/mercury/internal/releasebuild/artifact_upload.go" ]] || {
  log "COSMOS_ROOT is not a Cosmos checkout"
  exit 1
}

VECTOR="${ROOT_DIR}/scripts/tests/fixtures/orion-v1-vector.json"
expected="sha256:0ef043419d2de6704241f6b0809f17f4776ce9c1687ebf1adb7c8a49c11b48da"
actual="$(compute_spec_hash "$VECTOR")"
if [[ "$actual" != "$expected" ]]; then
  log "runall canonical hash drifted from the Go/Orion vector"
  exit 1
fi

python3 - "${COSMOS_ROOT}/solar/mercury/internal/releasebuild/artifact_upload.go" "${ROOT_DIR}/scripts/upload-artifacts" <<'PY'
import re, sys
from pathlib import Path
go = Path(sys.argv[1]).read_text(encoding="utf-8")
uploader = Path(sys.argv[2]).read_text(encoding="utf-8")

def tags(struct):
    match = re.search(rf"type {struct} struct \{{(.*?)\n\}}", go, re.S)
    if not match:
        raise SystemExit(f"missing {struct}")
    found = re.findall(r'`json:"([^,"]+)', match.group(1))
    if not found:
        raise SystemExit(f"{struct} has no json tags")
    return set(found)

request = tags("ArtifactUploadRequest")
grant = tags("ArtifactUploadGrant")
for name in ("target", "fileName", "contentType", "byteSize", "sha256"):
    if name not in request or name not in grant:
        raise SystemExit(f"Mercury schema missing {name}")
if "objectKey" not in grant:
    raise SystemExit("Mercury grant schema missing objectKey")
if "size:" in uploader or 'json:"size"' in uploader:
    raise SystemExit("uploader still sends size")
for name in ("byteSize", "artifact-uploads", "/complete", "objectKey"):
    if name not in uploader:
        raise SystemExit(f"uploader missing {name}")
PY

# Confirm the callback route still completes an authorized upload before download.
python3 - "${COSMOS_ROOT}/solar/mercury/internal/releasebuild/api.go" "${COSMOS_ROOT}/solar/mercury/internal/releasebuild/artifact_upload.go" <<'PY'
from pathlib import Path
import sys
api = Path(sys.argv[1]).read_text(encoding="utf-8")
upload = Path(sys.argv[2]).read_text(encoding="utf-8")
for needle in (
    "/internal/build-runs/{runId}/artifact-uploads",
    "/internal/build-runs/{runId}/artifact-uploads/{target}/complete",
    "/build-runs/{runId}/artifacts/{target}/download",
):
    if needle not in api:
        raise SystemExit(f"missing Mercury route {needle}")
if "artifactDownloadable" not in upload or "func artifactIsDownloadable" not in upload:
    raise SystemExit("download remains gated on verified artifacts")
PY

python3 - "${COSMOS_ROOT}/solar/mercury/internal/releasebuild/signing_material.go" "${ROOT_DIR}/scripts/lib/signing_policy.py" <<'PY'
import re, sys
from pathlib import Path
go = Path(sys.argv[1]).read_text(encoding="utf-8")
policy = Path(sys.argv[2]).read_text(encoding="utf-8")
for struct in ("AndroidSigningMaterial", "IOSSigningMaterial"):
    match = re.search(rf"type {struct} struct \{{(.*?)\n\}}", go, re.S)
    if not match:
        raise SystemExit(f"missing {struct}")
    tags = re.findall(r'`json:"([^,"]+)', match.group(1))
    if not tags:
        raise SystemExit(f"{struct} has no json tags")
    for tag in tags:
        if tag not in policy:
            raise SystemExit(f"signing policy does not honor Mercury field {tag}")
PY

flutter_bin="${RUNALL_FLUTTER_BIN:-/root/fvm/versions/3.47.2/bin/flutter}"
dart_bin="${RUNALL_DART_BIN:-/root/fvm/versions/3.47.2/bin/dart}"
[[ -x "$flutter_bin" && -x "$dart_bin" ]] || {
  log "pinned Flutter 3.47.2 is not available; schema check passed, generator not executed"
  exit 0
}

work="$(mktemp -d "${TMPDIR:-/tmp}/runall-cross-XXXXXX")"
clone="${work}/orion"
git clone --shared "$ORION_ROOT" "$clone" >/dev/null
head_sha="$(git -C "$clone" rev-parse HEAD)"
if [[ "$head_sha" != "fe436419fb3268d2174c89a14237734a145f3e71" ]]; then
  log "ORION_ROOT is not the delivered Orion SHA $head_sha"
  exit 1
fi
(cd "${clone}/apps/rigel" && "$flutter_bin" pub get --offline)

python3 - "$VECTOR" "$work" "$head_sha" <<'PY'
import hashlib, json, struct, sys, zlib
from pathlib import Path
vector, work, commit = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

def png(width, height, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )

def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()

root = work / "resources"
root.mkdir()
icon = png(32, 32, (220, 10, 10))
ftl = b"hello = Frozen\n"
(root / "icon.png").write_bytes(icon)
(root / "en.ftl").write_bytes(ftl)
(root / "index.json").write_text(
    json.dumps({"oss://brand/app-icon.png": "icon.png", "oss://languages/en.ftl": "en.ftl"}) + "\n",
    encoding="utf-8",
)
spec = json.loads(vector.read_text(encoding="utf-8"))
spec["status"] = "ready"
spec["repository"] = "https://github.com/prtmax/orion.git"
spec["sourceCommit"] = commit
spec["platform"] = "android"
spec["targets"] = ["aab", "apk"]
spec["config"]["orion"]["commit"] = commit
app = spec["config"]["app"]
app["displayName"] = "Frozen App"
app["versionName"] = "1.2.3"
app["versionCode"] = 42
app["applicationId"] = "com.example.frozen"
app["bundleId"] = "com.example.frozen"
spec["config"]["brandAssets"] = [{"kind": "icon", "ref": "oss://brand/app-icon.png", "digest": digest(icon)}]
spec["config"]["languages"] = [{"locale": "en", "ref": "oss://languages/en.ftl", "digest": digest(ftl)}]
spec.pop("specHash", None)
(work / "spec.json").write_text(json.dumps(spec) + "\n", encoding="utf-8")
bad = json.loads(json.dumps(spec))
bad_bytes = b"not-a-png"
(root / "bad.png").write_bytes(bad_bytes)
bad["config"]["brandAssets"][0]["digest"] = digest(bad_bytes)
(work / "bad-spec.json").write_text(json.dumps(bad) + "\n", encoding="utf-8")
(root / "bad-index.json").write_text(
    json.dumps({"oss://brand/app-icon.png": "bad.png", "oss://languages/en.ftl": "en.ftl"}) + "\n",
    encoding="utf-8",
)
PY

hash_spec() {
  local src="$1" dest="$2" hashed
  hashed="$(compute_spec_hash "$src")"
  jq --arg h "$hashed" '.specHash = $h' "$src" > "$dest"
}
hash_spec "${work}/spec.json" "${work}/android-spec.json"
jq '.platform = "ios" | .targets = ["ipa"] | del(.specHash)' "${work}/android-spec.json" > "${work}/ios-raw.json"
hash_spec "${work}/ios-raw.json" "${work}/ios-spec.json"
hash_spec "${work}/bad-spec.json" "${work}/bad-hashed.json"

tool="${work}/bin"
mkdir -p "$tool"
cat > "${tool}/flutter" <<'EOF'
#!/usr/bin/env bash
printf 'Flutter 3.47.2\n'
if [[ "$*" == *"build apk"* ]]; then
  test -f android/app/src/main/res/mipmap-mdpi/ic_launcher.png
  mkdir -p build/app/outputs/flutter-apk
  printf 'apk' > build/app/outputs/flutter-apk/app-release.apk
fi
if [[ "$*" == *"build appbundle"* ]]; then
  mkdir -p build/app/outputs/bundle/release
  printf 'aab' > build/app/outputs/bundle/release/app-release.aab
fi
if [[ "$*" == *"build ios"* ]]; then
  test -f ios/Flutter/Branded.xcconfig
  grep -q 'IOS_BUNDLE_ID=com.example.frozen' ios/Flutter/Branded.xcconfig
  mkdir -p build/ios/iphoneos/Runner.app
  python3 - ios/Flutter/Branded.xcconfig build/ios/iphoneos/Runner.app/Info.plist "$@" <<'PY'
import plistlib, sys
from pathlib import Path
branded = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        key, value = line.split("=", 1)
        branded[key] = value
args = sys.argv[3:]
def flag(name):
    return args[args.index(name) + 1]
info = {
    "CFBundleIdentifier": branded["IOS_BUNDLE_ID"],
    "CFBundleDisplayName": branded["APP_DISPLAY_NAME"],
    "CFBundleShortVersionString": flag("--build-name"),
    "CFBundleVersion": flag("--build-number"),
}
Path(sys.argv[2]).write_bytes(plistlib.dumps(info))
PY
fi
EOF
cat > "${tool}/aapt" <<'EOF'
#!/usr/bin/env bash
printf "%s\n" "package: name='com.example.frozen' versionCode='42' versionName='1.2.3'"
EOF
chmod +x "${tool}/flutter" "${tool}/aapt"

export RUNALL_FLUTTER="${tool}/flutter"
export RUNALL_DART="$dart_bin"
export RUNALL_FROZEN_RESOURCE_ROOT="${work}/resources"
export PATH="${tool}:${PATH}"
"${ROOT_DIR}/scripts/build-android" \
  --spec "${work}/android-spec.json" \
  --workspace "$clone" \
  --output-dir "${work}/android-out"
test -f "${work}/android-out/app-release.apk"
test -f "${work}/android-out/app-release.aab"
python3 - "${work}/android-out" "${clone}/apps/rigel/.runall/release-build/dart-defines.json" <<'PY'
import json, sys
from pathlib import Path
defines = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if defines.get("MERCURY_BASE_URL") != "https://mercury.example":
    raise SystemExit("real generator did not emit the frozen Mercury endpoint")
if defines.get("RUNTIME_BASE_URL") != "https://runtime.example":
    raise SystemExit("real generator did not emit the frozen runtime endpoint")
PY
if RUNALL_RESOURCE_INDEX="${work}/resources/bad-index.json" "${ROOT_DIR}/scripts/build-android" \
  --spec "${work}/bad-hashed.json" \
  --workspace "$clone" \
  --output-dir "${work}/bad-out"; then
  log "corrupt frozen PNG was accepted"
  exit 1
fi
test ! -e "${work}/bad-out/app-release.apk"
test ! -e "${work}/bad-out/app-release.aab"
"${ROOT_DIR}/scripts/build-ios" \
  --spec "${work}/ios-spec.json" \
  --workspace "$clone" \
  --output-dir "${work}/ios-out"
test -f "${work}/ios-out/Runner.app.tar"
log "cross-repo contract passed at orion ${head_sha}"
