#!/usr/bin/env bash
# Verify the shared JCS vector and real Orion native assembler offline.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/lib/common.sh"
assert_non_empty "ORION_ROOT" "${ORION_ROOT:-}"
assert_non_empty "COSMOS_ROOT" "${COSMOS_ROOT:-}"
assembler="${ORION_ROOT}/tools/app_assembler/assemble.py"
vector="${COSMOS_ROOT}/fornax/dalim/fixtures/native/canonical-vectors.json"
[[ -f "$assembler" && -f "$vector" ]] || { log "Orion/Cosmos native contract files are missing"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/runall-native-cross-XXXXXX")"
jq '{buildInput:(.[] | select(.kind == "build") | .normalized)}' "$vector" > "$work/vector.json"
expected="$(jq -r '.[] | select(.kind == "build") | .digest' "$vector")"
actual="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" input "$work/vector.json")"
[[ "$actual" == "$expected" ]] || { log "runall JCS digest differs from the Cosmos vector"; exit 1; }

python3 - "$work" <<'PY'
import hashlib, json, struct, sys, zlib
from pathlib import Path
root = Path(sys.argv[1])
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
row = b"\x00" + b"\x22\x88\xcc" * 1024
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(row * 1024)) + chunk(b"IEND", b"")
(root / "icon.png").write_bytes(png)
(root / "oversized.png").write_bytes(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(b"\0" * ((1024 * 3 + 1) * 1024 + 1)))
    + chunk(b"IEND", b"")
)
(root / "en.ftl").write_text("home = Home\n", encoding="utf-8")
PY
icon_digest="$(sha256_file "$work/icon.png")"
locale_digest="$(sha256_file "$work/en.ftl")"
theme_fixture="${COSMOS_ROOT}/solar/mercury/internal/theme/testdata/native-theme-tokens.json"
[[ -f "$theme_fixture" ]] || { log "Mercury theme output fixture is missing"; exit 1; }
jq --arg icon "$icon_digest" --arg locale "$locale_digest" --slurpfile theme "$theme_fixture" '
  .buildInput.themes |= map(.themeKey = "cosmos-default" | .tokens = $theme[0]) |
  .buildInput.resources = [
    {kind:"app_icon",key:"app_icon",ref:"app-studio/icon",digest:$icon,contentType:"image/png"},
    {kind:"localization",key:"en",ref:"app-studio/en",digest:$locale,contentType:"text/plain; charset=utf-8"}
  ] |
  .platform = "android" | .targets = ["apk"]
' "$work/vector.json" > "$work/spec.json"
printf '{"app-studio/icon":"icon.png","app-studio/en":"en.ftl"}\n' > "$work/index.json"
(cd "${ORION_ROOT}/apps/rigel" && python3 "$assembler" "$work/spec.json" "$work/output" "$work/index.json")
generated="$work/output/overlay/lib/bootstrap/development_assembly.dart"
grep -q 'MellowHomePresentation' "$generated"
grep -q 'BreezePersonalCenterPresentation' "$generated"
grep -q 'colors.primary' "$generated"
grep -q '#0B6BCB' "$generated"

jq '.buildInput.app.displayName="${throw StateError(\"injected\")}"' "$work/spec.json" > "$work/unsafe-display.json"
if (cd "${ORION_ROOT}/apps/rigel" && python3 "$assembler" "$work/unsafe-display.json" "$work/unsafe-output" "$work/index.json") >/dev/null 2>&1; then
  log "Dart interpolation was accepted in the native display name"
  exit 1
fi
jq '.buildInput.environment.runtimeBaseUrl="https://example.test/${runtime}" | .buildInput.themes[0].tokens["typography.title"]="${title}"' "$work/spec.json" > "$work/literal-spec.json"
(cd "${ORION_ROOT}/apps/rigel" && python3 "$assembler" "$work/literal-spec.json" "$work/literal-output" "$work/index.json")
literal="$work/literal-output/overlay/lib/bootstrap/development_assembly.dart"
grep -Fq 'https://example.test/\${runtime}' "$literal"
grep -Fq '\${title}' "$literal"
grep -q 'presentations: const' "$generated"
test -f "$work/output/overlay/android/app/src/main/AndroidManifest.xml"
grep -q 'android:label="Native Demo"' "$work/output/overlay/android/app/src/main/AndroidManifest.xml"
grep -q 'ANDROID_APPLICATION_ID' "$work/output/overlay/android/app/build.gradle.kts"

jq '.platform="ios" | .targets=["ipa"]' "$work/spec.json" > "$work/ios-spec.json"
(cd "${ORION_ROOT}/apps/rigel" && python3 "$assembler" "$work/ios-spec.json" "$work/ios-output" "$work/index.json")
grep -q 'IOS_BUNDLE_ID=com.example.native' "$work/ios-output/overlay/ios/Flutter/Branded.xcconfig"
grep -q 'PRODUCT_BUNDLE_IDENTIFIER = $(IOS_BUNDLE_ID)' "$work/ios-output/overlay/ios/Runner.xcodeproj/project.pbxproj"
python3 - "$work/ios-output/overlay/ios/Runner/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
if info.get("CFBundleDisplayName") != "$(APP_DISPLAY_NAME)":
    raise SystemExit("iOS display name is not bound to the frozen config")
PY
oversized_digest="$(sha256_file "$work/oversized.png")"
jq --arg digest "$oversized_digest" '.buildInput.resources[0].digest=$digest | .buildInput.resources[0].ref="app-studio/oversized"' "$work/ios-spec.json" > "$work/oversized-spec.json"
printf '{"app-studio/oversized":"oversized.png","app-studio/en":"en.ftl"}\n' > "$work/oversized-index.json"
if (cd "${ORION_ROOT}/apps/rigel" && python3 "$assembler" "$work/oversized-spec.json" "$work/oversized-output" "$work/oversized-index.json") >/dev/null 2>&1; then
  log "PNG expanding beyond its declared scanlines was accepted"
  exit 1
fi

log "cross-repo native contract passed"
