#!/usr/bin/env bash
# Local contract tests for runall executor scripts (no network).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

FIXTURE="${ROOT_DIR}/scripts/tests/fixtures/android-apk-spec.json"
TMPDIR="$(mktemp -d)"
trap 'find "${TMPDIR}" -mindepth 1 -maxdepth 1 -type f -exec rm -f {} \;' EXIT

log "contract: load-build-spec from fixture"
BUILD_SPEC_FILE="$FIXTURE" \
  "${ROOT_DIR}/scripts/load-build-spec" --output "${TMPDIR}/spec.json" --run-id run-contract-test

log "contract: reject invalid platform targets"
invalid="${TMPDIR}/invalid.json"
jq '.targets = ["ipa"]' "$FIXTURE" > "$invalid"
if BUILD_SPEC_FILE="$invalid" "${ROOT_DIR}/scripts/load-build-spec" --output "${TMPDIR}/bad.json" 2>/dev/null; then
  log "expected validation failure for android+ipa targets"
  exit 1
fi

log "contract: reject specHash without sha256 prefix"
bad_hash="${TMPDIR}/bad-hash.json"
jq '.specHash = "md5:abc"' "$FIXTURE" > "$bad_hash"
if BUILD_SPEC_FILE="$bad_hash" "${ROOT_DIR}/scripts/load-build-spec" --output "${TMPDIR}/bad2.json" 2>/dev/null; then
  log "expected specHash validation failure"
  exit 1
fi

log "contract: reject specHash that does not match canonical document"
tampered="${TMPDIR}/tampered.json"
jq '.config.app.applicationId = "com.example.tampered"' "$FIXTURE" > "$tampered"
if BUILD_SPEC_FILE="$tampered" "${ROOT_DIR}/scripts/load-build-spec" --output "${TMPDIR}/bad3.json" 2>/dev/null; then
  log "expected canonical specHash mismatch failure"
  exit 1
fi

log "contract: compute_spec_hash matches fixture"
computed="$(compute_spec_hash "$FIXTURE")"
declared="$(jq -r .specHash "$FIXTURE")"
if [[ "$computed" != "$declared" ]]; then
  log "fixture specHash inconsistent with compute_spec_hash"
  exit 1
fi

log "contract: exchange-build-credential OIDC request shape (dry run)"
exchange_out="${TMPDIR}/exchange.env"
export COSMOS_BUILD_AUTH_EXCHANGE_URL="https://example.test/internal/build-auth/exchange"
export COSMOS_BUILD_OIDC_TOKEN="test-oidc-token"
export BUILD_RUN_ID="run-contract-test"
exchange_payload="${TMPDIR}/exchange-payload.json"
mock_bin2="${TMPDIR}/bin2"
mkdir -p "$mock_bin2"
cat > "${mock_bin2}/curl" <<'MOCK2'
#!/usr/bin/env bash
if [[ "${1:-}" == "--fail-with-body" ]]; then
  shift
fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--data-binary" ]]; then
    echo "$2" > "${MOCK_EXCHANGE_PAYLOAD:?}"
    echo '{"accessToken":"scoped-test-token"}'
    exit 0
  fi
  shift
done
exit 1
MOCK2
chmod +x "${mock_bin2}/curl"
export PATH="${mock_bin2}:${PATH}"
export MOCK_EXCHANGE_PAYLOAD="${exchange_payload}"
"${ROOT_DIR}/scripts/exchange-build-credential" --run-id run-contract-test --output-env "$exchange_out"
jq -e '.runId == "run-contract-test" and .githubOidcToken == "test-oidc-token"' "$exchange_payload" >/dev/null
grep -q 'COSMOS_BUILD_CREDENTIAL=scoped-test-token' "$exchange_out"

log "contract: upload-artifacts presign body shape (dry run)"
upload_payload="${TMPDIR}/upload-payload.json"
printf 'fake-apk' > "${TMPDIR}/fake.apk"
export COSMOS_BUILD_ARTIFACT_UPLOAD_URL="https://example.test/internal"
export COSMOS_BUILD_CREDENTIAL="test-credential"
export BUILD_RUN_ID="run-contract-test"
complete_payload="${TMPDIR}/complete-payload.json"
cat > "${mock_bin2}/curl" <<'MOCK3'
#!/usr/bin/env bash
args=("$@")
joined="$*"
data=""
prev=""
for arg in "${args[@]}"; do
  if [[ "$prev" == "--data-binary" ]]; then data="$arg"; fi
  prev="$arg"
done
if [[ "$joined" == *" -X PUT "* || "$joined" == *" -X PUT" ]]; then
  printf 'put
' >> "${MOCK_UPLOAD_LOG:?}"
  exit 0
fi
if [[ "$joined" == *"/complete"* ]]; then
  printf '%s
' "$data" > "${MOCK_COMPLETE_PAYLOAD:?}"
  printf '{}
'
  exit 0
fi
if [[ -n "$data" ]]; then
  printf '%s
' "$data" > "${MOCK_UPLOAD_PAYLOAD:?}"
  size=$(wc -c < "${MOCK_UPLOAD_ARTIFACT:?}" | tr -d ' ')
  digest=$(sha256sum "${MOCK_UPLOAD_ARTIFACT}" | awk '{print $1}')
  printf '{"url":"https://example.test/put","method":"PUT","objectKey":"builds/contract/apk/%s/fake.apk","fileName":"fake.apk","contentType":"application/vnd.android.package-archive","byteSize":%s,"sha256":"%s","target":"apk","headers":{}}
' "$digest" "$size" "$digest"
  exit 0
fi
exit 1
MOCK3
chmod +x "${mock_bin2}/curl"
export MOCK_UPLOAD_PAYLOAD="${upload_payload}"
export MOCK_UPLOAD_ARTIFACT="${TMPDIR}/fake.apk"
export MOCK_COMPLETE_PAYLOAD="${complete_payload}"
export MOCK_UPLOAD_LOG="${TMPDIR}/upload.log"
: > "$MOCK_UPLOAD_LOG"
"${ROOT_DIR}/scripts/upload-artifacts" \
  --spec "${TMPDIR}/spec.json" \
  --artifact "${TMPDIR}/fake.apk" \
  --target apk
jq -e '.target == "apk" and .fileName == "fake.apk" and .byteSize > 0 and (.sha256 | test("^[0-9a-f]{64}$")) and (.size | not)' "$upload_payload" >/dev/null
jq -e --slurpfile auth "$upload_payload" '.target == "apk" and .objectKey == ("builds/contract/apk/" + $auth[0].sha256 + "/fake.apk") and .byteSize == $auth[0].byteSize and .sha256 == $auth[0].sha256' "$complete_payload" >/dev/null
grep -q put "$MOCK_UPLOAD_LOG"

log "contract: report-result payload shape (dry run)"
export COSMOS_BUILD_CALLBACK_URL="https://example.test/callback"
export COSMOS_BUILD_CREDENTIAL="test-credential"
export BUILD_RUN_ID="run-contract-test"
export GITHUB_RUN_ID="12345"
export GITHUB_SERVER_URL="https://github.com"
export GITHUB_REPOSITORY="prtmax/runall"

payload_file="${TMPDIR}/payload.json"
mock_bin="${TMPDIR}/bin"
mkdir -p "$mock_bin"
cat > "${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--fail-with-body" ]]; then
  shift
fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--data-binary" ]]; then
    echo "$2" > "${MOCK_PAYLOAD_OUT:?}"
    exit 0
  fi
  shift
done
exit 1
MOCK
chmod +x "${mock_bin}/curl"
export PATH="${mock_bin}:${PATH}"
export MOCK_PAYLOAD_OUT="${payload_file}"
"${ROOT_DIR}/scripts/report-result" --status running --phase prepare --run-id run-contract-test
jq -e '.status == "running" and .phase == "prepare" and .externalRunId == "12345"' "$payload_file" >/dev/null

log "contract: Go/Orion v1 canonical vector"
orion_fixture="${ROOT_DIR}/scripts/tests/fixtures/orion-v1-vector.json"
orion_hash="$(compute_spec_hash "$orion_fixture")"
if [[ "$orion_hash" != "sha256:0ef043419d2de6704241f6b0809f17f4776ce9c1687ebf1adb7c8a49c11b48da" ]]; then
  log "canonical vector mismatch: $orion_hash"
  exit 1
fi
python3 - "$orion_fixture" <<'PY'
import importlib.util, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("spec_hash", root.parents[2] / "lib" / "spec_hash.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
doc = json.loads(root.read_text())
reordered = json.loads(root.read_text())
bundled = reordered["config"]["release"]["bundled"]
reordered["config"]["release"]["bundled"] = {key: bundled[key] for key in reversed(list(bundled))}
reordered["targets"] = ["apk", "aab", "apk"]
reordered["releaseSnapshot"] = {"tampered": True}
if module.canonical_bytes(reordered) != module.canonical_bytes(doc):
    raise SystemExit("normalization changed the v1 payload")
reordered["config"]["app"]["versionCode"] = 9007199254740994
if module.canonical_bytes(reordered) == module.canonical_bytes(doc):
    raise SystemExit("large integer tamper was ignored")
reordered = json.loads(root.read_text())
reordered["releaseSnapshotDigest"] = "sha256:" + "ab" * 32
if module.canonical_bytes(reordered) == module.canonical_bytes(doc):
    raise SystemExit("snapshot digest tamper was ignored")
try:
    bad = json.loads(root.read_text())
    bad["config"]["app"]["versionCode"] = "7"
    module.canonical_bytes(bad)
except SystemExit:
    pass
else:
    raise SystemExit("string versionCode was accepted")
PY

log "contract: resource digest is recomputed"
resource_root="${TMPDIR}/resources"
mkdir -p "$resource_root"
printf 'brand-bytes' > "${resource_root}/icon.bin"
resource_hash="sha256:$(sha256_file "${resource_root}/icon.bin")"
resource_spec="${TMPDIR}/resource-spec.json"
jq --arg digest "$resource_hash" '.resources = [{"path":"icon.bin","sha256":$digest}]' "$FIXTURE" > "$resource_spec"
resource_spec_hash="$(compute_spec_hash "$resource_spec")"
jq --arg h "$resource_spec_hash" '.specHash = $h' "$resource_spec" > "${TMPDIR}/resource-spec-hashed.json"
RUNALL_RESOURCE_ROOT="$resource_root" BUILD_SPEC_FILE="${TMPDIR}/resource-spec-hashed.json" \
  "${ROOT_DIR}/scripts/load-build-spec" --output "${TMPDIR}/resource-ok.json" --run-id run-contract-test
printf 'other' > "${resource_root}/icon.bin"
if RUNALL_RESOURCE_ROOT="$resource_root" BUILD_SPEC_FILE="${TMPDIR}/resource-spec-hashed.json" \
  "${ROOT_DIR}/scripts/load-build-spec" --output "${TMPDIR}/resource-bad.json" 2>/dev/null; then
  log "expected resource digest mismatch"
  exit 1
fi

log "contract: build-android has no keystore or token arguments"
if "${ROOT_DIR}/scripts/build-android" --help >/dev/null && "${ROOT_DIR}/scripts/build-android" --keystore /tmp/nope 2>/dev/null; then
  log "build-android accepted a keystore argument"
  exit 1
fi
if grep -q 'COSMOS_BUILD_REPOSITORY_TOKEN\|id-token\|keystore' "${ROOT_DIR}/scripts/build-android"; then
  log "build-android script still references token, OIDC, or keystore"
  exit 1
fi

log "contract: workflow split keeps compile unprivileged"
workflow="${ROOT_DIR}/.github/workflows/android-build.yml"
python3 - "$workflow" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("  build-android:")
rest = text[start+len("  build-android:"):]
next_job = rest.find("\n  sign-android:")
job = rest[:next_job]
if "id-token:" in job or "COSMOS_BUILD_REPOSITORY_TOKEN" in job or "COSMOS_BUILD_CREDENTIAL" in job:
    raise SystemExit("compile job still has OIDC or a long-lived token")
if "contents: read" not in job:
    raise SystemExit("compile job missing contents: read")
for name in ("reusable-prepare.yml", "reusable-sign-android.yml", "reusable-finalize-android.yml", "reusable-sign-ios.yml", "reusable-finalize-ios.yml"):
    if name not in text:
        raise SystemExit(f"missing reusable workflow call: {name}")
ios = text[text.index("  build-ios:"):text.index("  sign-ios:")]
if "id-token:" in ios or "COSMOS_BUILD_REPOSITORY_TOKEN" in ios or "COSMOS_BUILD_CREDENTIAL" in ios:
    raise SystemExit("ios compile job still has OIDC or a repository token")
if "frozen-resources-${{ inputs.build_run_id }}" not in job or "frozen-resources-${{ inputs.build_run_id }}" not in ios:
    raise SystemExit("compile job does not download the frozen resource artifact")
if "RUNALL_FROZEN_RESOURCE_ROOT=\"${PWD}/frozen-resources\"" not in job or "RUNALL_FROZEN_RESOURCE_ROOT=\"${PWD}/frozen-resources\"" not in ios:
    raise SystemExit("compile job does not point at the downloaded frozen resources")
prepare = open(sys.argv[1].replace("android-build.yml", "reusable-prepare.yml"), encoding="utf-8").read()
if "stage-frozen-resources" not in prepare or "frozen-resources-${{ inputs.build_run_id }}" not in prepare:
    raise SystemExit("prepare does not stage and upload frozen resources")
if "id-token: write" not in prepare:
    raise SystemExit("prepare lost its OIDC permission")
if "upstream_result" not in text:
    raise SystemExit("finalize is not wired to upstream failure")
if "run-name: cosmos-build-${{ inputs.build_run_id }}" not in text:
    raise SystemExit("dispatch run-name must include the platform build run id")
if "build_spec_id" in text:
    raise SystemExit("dispatch workflow still accepts build_spec_id")
PY
finalize="${ROOT_DIR}/.github/workflows/reusable-finalize-android.yml"
grep -q "upstream_result != 'success'" "$finalize"
grep -q 'COSMOS_BUILD_CALLBACK_URL: ${{ secrets.COSMOS_BUILD_CALLBACK_URL }}' "$finalize"
if grep -q 'COSMOS_BUILD_CREDENTIAL: ${{ env.COSMOS_BUILD_CREDENTIAL }}' "$finalize"; then
  log "finalize rebinds credential from the workflow env context"
  exit 1
fi
grep -q 'scripts/sign-aab' "${ROOT_DIR}/.github/workflows/reusable-sign-android.yml"
grep -q 'source-workspace.tar' "${ROOT_DIR}/.github/workflows/reusable-prepare.yml"
grep -q 'source-workspace.tar' "${ROOT_DIR}/.github/workflows/android-build.yml"
grep -q -- '--target aab' "$finalize"
grep -q 'scripts/sign-ios' "${ROOT_DIR}/.github/workflows/reusable-sign-ios.yml"
grep -q -- '--target ipa' "${ROOT_DIR}/.github/workflows/reusable-finalize-ios.yml"
grep -q -- '--no-codesign' "${ROOT_DIR}/scripts/build-ios"

log "contract: checkout-source does not persist the clone token"
checkout_root="${TMPDIR}/checkout"
mkdir -p "$checkout_root"
mock_git_bin="${TMPDIR}/gitbin"
mkdir -p "$mock_git_bin"
cat > "${mock_git_bin}/git" <<'MOCKGIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_GIT_LOG:?}"
if [[ "$*" == *"http.extraheader"* && "$*" == *"x-access-token:super-secret-token"* ]]; then
  echo "token leaked into git arguments" >> "${MOCK_GIT_LOG}"
  exit 1
fi
if [[ "$1" == "init" ]]; then
  mkdir -p "$2/.git"
  exit 0
fi
if [[ "$1" == "-C" && "$3" == "checkout" ]]; then
  mkdir -p "$2/apps/rigel/tool"
  touch "$2/apps/rigel/tool/generate_release_build.dart"
  exit 0
fi
if [[ "$*" == *"rev-parse HEAD"* ]]; then
  if [[ "$*" == *"orion"* ]]; then
    printf '%s\n' "0000000000000000000000000000000000000002"
  else
    printf '%s\n' "0000000000000000000000000000000000000001"
  fi
  exit 0
fi
if [[ "$*" == *"remote get-url origin"* ]]; then
  printf '%s\n' "https://github.com/prtmax/orion.git"
  exit 0
fi
exit 0
MOCKGIT
chmod +x "${mock_git_bin}/git"
export MOCK_GIT_LOG="${TMPDIR}/git.log"
: > "$MOCK_GIT_LOG"
PATH="${mock_git_bin}:${PATH}" COSMOS_BUILD_REPOSITORY_TOKEN="super-secret-token" \
  "${ROOT_DIR}/scripts/checkout-source" --spec "${TMPDIR}/spec.json" --workspace "${checkout_root}/src"
if grep -q 'x-access-token:super-secret-token@' "$MOCK_GIT_LOG"; then
  log "clone token was embedded in a git URL"
  exit 1
fi
if ! grep -q 'http.extraheader=AUTHORIZATION: basic' "$MOCK_GIT_LOG"; then
  log "expected per-command extraheader auth"
  exit 1
fi
if ! grep -q 'https://github.com/prtmax/orion.git' "$MOCK_GIT_LOG"; then
  log "expected public origin URL"
  exit 1
fi

log "contract: sign-android checks version and fingerprint, then deletes material"
sign_tmp="${TMPDIR}/signtmp"
mkdir -p "$sign_tmp"
printf 'dummy-apk' > "${TMPDIR}/unsigned.apk"
signed_spec="${TMPDIR}/signed-spec.json"
jq '.config.app.applicationId = "com.example.contract" | .config.app.versionName = "1.2.3" | .config.app.versionCode = 7' "$FIXTURE" > "$signed_spec"
signed_hash="$(compute_spec_hash "$signed_spec")"
jq --arg h "$signed_hash" '.specHash = $h' "$signed_spec" > "${TMPDIR}/signed-spec-hashed.json"
mock_sign_bin="${TMPDIR}/signbin"
mkdir -p "$mock_sign_bin"
cat > "${mock_sign_bin}/curl" <<'MOCKCURL'
#!/usr/bin/env bash
data=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--data-binary" ]]; then data="$arg"; fi
  prev="$arg"
done
if [[ "$*" == *"sign-results"* ]]; then
  printf '%s\n' "$data" > "${MOCK_SIGN_PAYLOAD:?}"
  exit 0
fi
if [[ "$*" == *"android-signing"* ]]; then
  printf '%s\n' "{\"keystoreBase64\":\"aGVsbG8=\",\"keystorePassword\":\"ks-secret\",\"keyPassword\":\"key-secret\",\"keyAlias\":\"alias-secret\",\"certificateSha256\":\"${MOCK_ANDROID_CERT:-}\"}"
  exit 0
fi
exit 1
MOCKCURL
cat > "${mock_sign_bin}/zipalign" <<'MOCKZ'
#!/usr/bin/env bash
exit 0
MOCKZ
cat > "${mock_sign_bin}/apksigner" <<'MOCKA'
#!/usr/bin/env bash
printf 'apksigner\n' >> "${MOCK_TOOL_LOG:?}"
if [[ "$1" == "sign" ]]; then
  out=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--out" ]]; then out="$arg"; fi
    prev="$arg"
  done
  printf 'signed' > "$out"
  exit 0
fi
if [[ "$*" == *"--print-certs"* ]]; then
  printf '%s\n' "Signer #1 certificate SHA-256 digest: ${MOCK_ANDROID_SIGNED_CERT:?}"
  exit 0
fi
exit 0
MOCKA
cat > "${mock_sign_bin}/aapt" <<'MOCKP'
#!/usr/bin/env bash
printf "%s\n" "package: name='com.example.contract' versionCode='7' versionName='1.2.3'"
MOCKP
chmod +x "${mock_sign_bin}/curl" "${mock_sign_bin}/zipalign" "${mock_sign_bin}/apksigner" "${mock_sign_bin}/aapt"
android_cert="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
signed_android_cert="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
sign_payload="${TMPDIR}/sign-payload.json"
tool_log="${TMPDIR}/tool.log"
: > "$tool_log"
if TMPDIR="$sign_tmp" PATH="${mock_sign_bin}:${PATH}" \
  MOCK_ANDROID_CERT="$android_cert" \
  MOCK_ANDROID_SIGNED_CERT="$signed_android_cert" \
  MOCK_SIGN_PAYLOAD="$sign_payload" \
  MOCK_TOOL_LOG="$tool_log" \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-android" \
    --spec "${TMPDIR}/signed-spec-hashed.json" \
    --input "${TMPDIR}/unsigned.apk" \
    --output "${TMPDIR}/signed.apk" \
    --expected-package "com.example.contract"; then
  log "expected fingerprint mismatch"
  exit 1
fi
if [[ -f "$sign_payload" ]]; then
  log "fingerprint mismatch still posted a sign receipt"
  exit 1
fi
if [[ -f "${TMPDIR}/signed.apk" ]]; then
  log "fingerprint mismatch left a signed apk"
  exit 1
fi
if find "$sign_tmp" -type f -print | grep -q .; then
  log "signing temp files were left behind"
  find "$sign_tmp" -type f -print >&2
  exit 1
fi

log "contract: sign-android refuses an empty certificate before signing"
: > "$tool_log"
rm -f "${TMPDIR}/signed.apk" "$sign_payload"
if PATH="${mock_sign_bin}:${PATH}" \
  MOCK_ANDROID_CERT="" \
  MOCK_ANDROID_SIGNED_CERT="$signed_android_cert" \
  MOCK_SIGN_PAYLOAD="$sign_payload" \
  MOCK_TOOL_LOG="$tool_log" \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CALLBACK_URL="https://example.test/callback" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-android" \
    --spec "${TMPDIR}/signed-spec-hashed.json" \
    --input "${TMPDIR}/unsigned.apk" \
    --output "${TMPDIR}/signed.apk" \
    --expected-package "com.example.contract"; then
  log "sign-android accepted an empty certificate"
  exit 1
fi
if [[ -f "${TMPDIR}/signed.apk" || -f "$sign_payload" ]] || grep -q apksigner "$tool_log"; then
  log "empty certificate still signed or posted a receipt"
  exit 1
fi

log "contract: sign-android refuses a string versionCode"
string_spec="${TMPDIR}/string-version-spec.json"
jq '.config.app.versionCode = "7"' "${TMPDIR}/signed-spec-hashed.json" > "$string_spec"
if compute_spec_hash "$string_spec" >/dev/null; then
  log "string versionCode was treated as canonical"
  exit 1
fi
if PATH="${mock_sign_bin}:${PATH}" \
  MOCK_ANDROID_CERT="$android_cert" \
  MOCK_ANDROID_SIGNED_CERT="$android_cert" \
  MOCK_SIGN_PAYLOAD="$sign_payload" \
  MOCK_TOOL_LOG="$tool_log" \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-android" \
    --spec "$string_spec" \
    --input "${TMPDIR}/unsigned.apk" \
    --output "${TMPDIR}/string.apk" \
    --expected-package "com.example.contract"; then
  log "sign-android accepted a string versionCode"
  exit 1
fi
if [[ -f "$sign_payload" ]]; then
  log "string versionCode posted a sign receipt"
  exit 1
fi

log "contract: sign-aab rejects fingerprint mismatch"
cat > "${mock_sign_bin}/jarsigner" <<'MOCKJ'
#!/usr/bin/env bash
printf 'jarsigner\n' >> "${MOCK_TOOL_LOG:?}"
exit 0
MOCKJ
cat > "${mock_sign_bin}/keytool" <<'MOCKK'
#!/usr/bin/env bash
printf '%s\n' "         SHA256: ${MOCK_ANDROID_SIGNED_CERT:?}"
MOCKK
cat > "${mock_sign_bin}/bundletool" <<'MOCKB'
#!/usr/bin/env bash
printf '%s\n' '<manifest package="com.example.contract" android:versionCode="7" android:versionName="1.2.3">'
MOCKB
chmod +x "${mock_sign_bin}/jarsigner" "${mock_sign_bin}/keytool" "${mock_sign_bin}/bundletool"
printf 'dummy-aab' > "${TMPDIR}/unsigned.aab"
aab_spec="${TMPDIR}/aab-spec.json"
jq '.targets = ["aab"] | .config.app.applicationId = "com.example.contract" | .config.app.versionName = "1.2.3" | .config.app.versionCode = 7' "$FIXTURE" > "$aab_spec"
aab_hash="$(compute_spec_hash "$aab_spec")"
jq --arg h "$aab_hash" '.specHash = $h' "$aab_spec" > "${TMPDIR}/aab-spec-hashed.json"
rm -f "$sign_payload"
if PATH="${mock_sign_bin}:${PATH}" \
  MOCK_ANDROID_CERT="$android_cert" \
  MOCK_ANDROID_SIGNED_CERT="$signed_android_cert" \
  MOCK_SIGN_PAYLOAD="$sign_payload" \
  MOCK_TOOL_LOG="$tool_log" \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-aab" \
    --spec "${TMPDIR}/aab-spec-hashed.json" \
    --input "${TMPDIR}/unsigned.aab" \
    --output "${TMPDIR}/signed.aab"; then
  log "expected AAB fingerprint mismatch"
  exit 1
fi
if [[ -f "$sign_payload" || -f "${TMPDIR}/signed.aab" ]]; then
  log "AAB fingerprint mismatch left a receipt or bundle"
  exit 1
fi
: > "$tool_log"
if PATH="${mock_sign_bin}:${PATH}" \
  MOCK_ANDROID_CERT="" \
  MOCK_ANDROID_SIGNED_CERT="$signed_android_cert" \
  MOCK_SIGN_PAYLOAD="$sign_payload" \
  MOCK_TOOL_LOG="$tool_log" \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CALLBACK_URL="https://example.test/callback" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-aab" \
    --spec "${TMPDIR}/aab-spec-hashed.json" \
    --input "${TMPDIR}/unsigned.aab" \
    --output "${TMPDIR}/empty-cert.aab"; then
  log "sign-aab accepted an empty certificate"
  exit 1
fi
if [[ -f "${TMPDIR}/empty-cert.aab" || -f "$sign_payload" ]] || grep -q jarsigner "$tool_log"; then
  log "empty AAB certificate still signed or posted a receipt"
  exit 1
fi

log "contract: ios build refuses signing material and sign-ios fails closed"
ios_spec="${TMPDIR}/ios-spec.json"
jq '.platform = "ios" | .targets = ["ipa"] | .config.app.bundleId = "com.example.contract" | .config.app.versionName = "1.2.3" | .config.app.versionCode = 7' "$FIXTURE" > "$ios_spec"
ios_hash="$(compute_spec_hash "$ios_spec")"
jq --arg h "$ios_hash" '.specHash = $h' "$ios_spec" > "${TMPDIR}/ios-spec-hashed.json"
if IOS_CERTIFICATE_PASSWORD=secret "${ROOT_DIR}/scripts/build-ios" \
  --spec "${TMPDIR}/ios-spec-hashed.json" \
  --workspace "${TMPDIR}/not-a-checkout" \
  --output-dir "${TMPDIR}/ios-out"; then
  log "build-ios accepted signing material"
  exit 1
fi
if "${ROOT_DIR}/scripts/build-ios" --spec "$FIXTURE" --workspace "${TMPDIR}" --output-dir "${TMPDIR}/ios-out"; then
  log "build-ios accepted an android spec"
  exit 1
fi
if "${ROOT_DIR}/scripts/sign-ios" \
  --spec "${TMPDIR}/ios-spec-hashed.json" \
  --input "${TMPDIR}/../Runner.app" \
  --output "${TMPDIR}/evil.ipa"; then
  log "sign-ios accepted a traversal path"
  exit 1
fi

ios_bin="${TMPDIR}/iosbin"
mkdir -p "$ios_bin" "${TMPDIR}/Runner.app"
python3 - "${TMPDIR}/Runner.app/Info.plist" <<'PY'
import plistlib, sys
plistlib.dump({
    "CFBundleIdentifier": "com.example.contract",
    "CFBundleShortVersionString": "1.2.3",
    "CFBundleVersion": "7",
}, open(sys.argv[1], "wb"))
PY
ios_cert="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat > "${ios_bin}/curl" <<'MOCKIOS'
#!/usr/bin/env bash
data=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--data-binary" ]]; then data="$arg"; fi
  prev="$arg"
done
if [[ "$*" == *"ios-signing"* ]]; then
  if [[ "${MOCK_IOS_MATERIAL:-full}" == "empty" ]]; then
    printf '%s\n' '{}'
    exit 0
  fi
  printf '%s\n' "${MOCK_IOS_MATERIAL_JSON:?}"
  exit 0
fi
if [[ "$*" == *"sign-results"* ]]; then
  printf '%s\n' "$data" > "${MOCK_SIGN_PAYLOAD:?}"
  exit 0
fi
exit 1
MOCKIOS
cat > "${ios_bin}/openssl" <<'MOCKSSL'
#!/usr/bin/env bash
if [[ "$*" == *"-fingerprint"* ]]; then
  printf 'SHA256 Fingerprint=%s\n' "$MOCK_IOS_FINGERPRINT"
fi
exit 0
MOCKSSL
cat > "${ios_bin}/security" <<'MOCKSEC'
#!/usr/bin/env python3
import datetime, os, plistlib, sys
args = sys.argv[1:]
log = os.environ.get("MOCK_SECURITY_LOG")
if log:
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(" ".join(args) + "\n")
if args[:1] == ["cms"]:
    plistlib.dump({
        "Name": os.environ.get("MOCK_PROFILE_NAME", "Release"),
        "TeamIdentifier": [os.environ["MOCK_IOS_TEAM"]],
        "ExpirationDate": datetime.datetime(2099, 1, 1, tzinfo=datetime.timezone.utc),
        "Entitlements": {"application-identifier": os.environ["MOCK_IOS_TEAM"] + ".com.example.contract"},
    }, sys.stdout.buffer)
elif args[:1] == ["find-identity"]:
    identity = os.environ["MOCK_IOS_IDENTITY"]
    sys.stdout.write(f"  1) {identity} \"Imported Identity\"\n     1 valid identities found\n")
raise SystemExit(0)
MOCKSEC
cat > "${ios_bin}/codesign" <<'MOCKCS'
#!/usr/bin/env bash
if [[ -n "${MOCK_CODESIGN_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$MOCK_CODESIGN_LOG"
fi
if [[ "$*" == *"--verify"* && "$*" != *"--sign"* ]]; then
  exit 0
fi
sign=""
prev=""
keychain=0
for arg in "$@"; do
  if [[ "$prev" == "--sign" ]]; then sign="$arg"; fi
  if [[ "$arg" == "--keychain" ]]; then keychain=1; fi
  prev="$arg"
done
printf '%s\n' "$sign" > "${MOCK_CODESIGN_IDENTITY:?}"
if [[ "$keychain" != 1 ]]; then
  exit 1
fi
if [[ ! "$sign" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  exit 1
fi
if [[ "${sign,,}" == "${MOCK_IOS_FINGERPRINT,,}" ]]; then
  exit 1
fi
if [[ "${sign,,}" != "${MOCK_IOS_IDENTITY,,}" ]]; then
  exit 1
fi
exit 0
MOCKCS
cat > "${ios_bin}/zip" <<'MOCKZIP'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in *.ipa) out="$arg" ;; esac
done
test -n "$out"
printf 'ipa' > "$out"
MOCKZIP
chmod +x "${ios_bin}/curl" "${ios_bin}/openssl" "${ios_bin}/security" "${ios_bin}/codesign" "${ios_bin}/zip"
material_json="$(jq -n --arg cert "$ios_cert" --arg p12 "$(printf p12 | base64)" --arg profile "$(printf profile | base64)" '{certificateP12Base64:$p12,certificatePassword:"pw",provisioningProfileBase64:$profile,teamId:"ABCDE12345",certificateSha256:$cert}')"
if PATH="${ios_bin}:${PATH}" \
  MOCK_IOS_MATERIAL=empty \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-ios" \
    --spec "${TMPDIR}/ios-spec-hashed.json" \
    --input "${TMPDIR}/Runner.app" \
    --output "${TMPDIR}/missing.ipa"; then
  log "sign-ios accepted empty signing material"
  exit 1
fi
if [[ -f "${TMPDIR}/missing.ipa" ]]; then
  log "sign-ios wrote an IPA without signing material"
  exit 1
fi
if PATH="${ios_bin}:${PATH}" \
  MOCK_IOS_MATERIAL=full \
  MOCK_IOS_MATERIAL_JSON="$material_json" \
  MOCK_IOS_FINGERPRINT="$ios_cert" \
  MOCK_IOS_IDENTITY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" \
  MOCK_IOS_TEAM="ZZZZZZZZZZ" \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-ios" \
    --spec "${TMPDIR}/ios-spec-hashed.json" \
    --input "${TMPDIR}/Runner.app" \
    --output "${TMPDIR}/wrong-team.ipa"; then
  log "sign-ios accepted a mismatched team"
  exit 1
fi
sign_payload="${TMPDIR}/ios-sign-payload.json"
ios_only="${TMPDIR}/ios-only-spec.json"
jq 'del(.config.app) | .config.ios.bundleId = "com.example.contract" | .config.ios.versionName = "1.2.3" | .config.ios.versionCode = "7"' "${TMPDIR}/ios-spec-hashed.json" > "$ios_only"
if compute_spec_hash "$ios_only" >/dev/null; then
  log "config.ios was treated as canonical"
  exit 1
fi
if "${ROOT_DIR}/scripts/sign-ios" \
  --spec "$ios_only" \
  --input "${TMPDIR}/Runner.app" \
  --output "${TMPDIR}/ios-only.ipa"; then
  log "sign-ios accepted config.ios instead of config.app"
  exit 1
fi
string_ios="${TMPDIR}/ios-string-spec.json"
jq '.config.app.versionCode = "7"' "${TMPDIR}/ios-spec-hashed.json" > "$string_ios"
if compute_spec_hash "$string_ios" >/dev/null; then
  log "ios string versionCode was treated as canonical"
  exit 1
fi
if "${ROOT_DIR}/scripts/sign-ios" \
  --spec "$string_ios" \
  --input "${TMPDIR}/Runner.app" \
  --output "${TMPDIR}/ios-string.ipa"; then
  log "sign-ios accepted a string versionCode"
  exit 1
fi
ios_identity="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
security_log="${TMPDIR}/security.log"
codesign_identity="${TMPDIR}/codesign-identity.txt"
codesign_log="${TMPDIR}/codesign.log"
mkdir -p "${TMPDIR}/Runner.app/Frameworks/Demo.framework"
printf 'framework' > "${TMPDIR}/Runner.app/Frameworks/Demo.framework/Demo"
ln -sfn Demo "${TMPDIR}/Runner.app/Frameworks/Demo.framework/DemoLink"
chmod 755 "${TMPDIR}/Runner.app/Frameworks/Demo.framework/Demo"
: > "$security_log"
: > "$codesign_log"
rm -f "$sign_payload"
PATH="${ios_bin}:${PATH}" \
  MOCK_IOS_MATERIAL=full \
  MOCK_IOS_MATERIAL_JSON="$material_json" \
  MOCK_IOS_FINGERPRINT="$ios_cert" \
  MOCK_IOS_IDENTITY="$ios_identity" \
  MOCK_IOS_TEAM="ABCDE12345" \
  MOCK_SIGN_PAYLOAD="$sign_payload" \
  MOCK_SECURITY_LOG="$security_log" \
  MOCK_CODESIGN_IDENTITY="$codesign_identity" \
  MOCK_CODESIGN_LOG="$codesign_log" \
  COSMOS_BUILD_SIGN_MATERIAL_URL="https://example.test/internal" \
  COSMOS_BUILD_CALLBACK_URL="https://example.test/callback" \
  COSMOS_BUILD_CREDENTIAL="test-credential" \
  BUILD_RUN_ID="run-contract-test" \
  "${ROOT_DIR}/scripts/sign-ios" \
    --spec "${TMPDIR}/ios-spec-hashed.json" \
    --input "${TMPDIR}/Runner.app" \
    --output "${TMPDIR}/signed.ipa"
jq -e --arg cert "$ios_cert" '.target == "ipa" and .packageName == "com.example.contract" and .versionName == "1.2.3" and .versionCode == 7 and .certSha256 == $cert and (.sha256 | test("^[0-9a-f]{64}$"))' "$sign_payload" >/dev/null
test -f "${TMPDIR}/signed.ipa"
grep -q '^import ' "$security_log"
grep -q '^find-identity ' "$security_log"
grep -q '^delete-keychain ' "$security_log"
test "$(cat "$codesign_identity")" = "$ios_identity"
grep -q 'Frameworks/Demo.framework' "$codesign_log"
grep -q -- '--entitlements' "$codesign_log"
framework_line="$(grep -n 'Frameworks/Demo.framework' "$codesign_log" | head -1 | cut -d: -f1)"
entitlement_line="$(grep -n -- '--entitlements' "$codesign_log" | head -1 | cut -d: -f1)"
if [[ "$framework_line" -ge "$entitlement_line" ]]; then
  log "nested code was not signed before the outer app"
  exit 1
fi

log "contract: source layout, absolute outputs, upload failures"
unset RUNALL_FLUTTER RUNALL_DART || true
layout_root="${TMPDIR}/layout"
mkdir -p "$layout_root"
git -C "$layout_root" init -q
git -C "$layout_root" config commit.gpgsign false
git -C "$layout_root" config user.email test@example.invalid
git -C "$layout_root" config user.name contract
mkdir -p "$layout_root/apps/rigel/tool" "$layout_root/apps/rigel/ios/Runner" "$layout_root/apps/rigel/ios/Flutter" "$layout_root/apps/rigel/assets/releases"
printf 'generator\n' > "$layout_root/apps/rigel/tool/generate_release_build.dart"
printf '{ "flutter": "3.47.2" }\n' > "$layout_root/.fvmrc"
printf 'IOS_BUNDLE_ID=com.aiyin.rigel\n' > "$layout_root/apps/rigel/ios/Flutter/Release.xcconfig"
python3 - "$layout_root/apps/rigel/ios/Runner/Info.plist" <<'PY'
import plistlib, sys
plistlib.dump({"CFBundleDisplayName": "Rigel", "CFBundleIdentifier": "com.aiyin.rigel"}, open(sys.argv[1], "wb"))
PY
git -C "$layout_root" add .
git -C "$layout_root" commit -q -m 'fixture app'
layout_sha="$(git -C "$layout_root" rev-parse HEAD)"
layout_resources="${TMPDIR}/layout-resources"
mkdir -p "$layout_resources"
printf 'icon-bytes' > "$layout_resources/icon.bin"
printf 'hello = Hello\n' > "$layout_resources/lang.ftl"
icon_digest="sha256:$(sha256_file "$layout_resources/icon.bin")"
lang_digest="sha256:$(sha256_file "$layout_resources/lang.ftl")"
icon_ref="$(jq -r '.config.brandAssets[0].ref' "$FIXTURE")"
lang_ref="$(jq -r '.config.languages[0].ref' "$FIXTURE")"
jq -n --arg icon "$icon_ref" --arg lang "$lang_ref" '{($icon): "icon.bin", ($lang): "lang.ftl"}' > "$layout_resources/index.json"
layout_spec="${TMPDIR}/layout-spec.json"
jq --arg sha "$layout_sha" --arg idigest "$icon_digest" --arg ldigest "$lang_digest" \
  '.sourceCommit = $sha | .config.orion.commit = $sha | .config.brandAssets[0].digest = $idigest | .config.languages[0].digest = $ldigest' \
  "$FIXTURE" > "$layout_spec"
layout_hash="$(compute_spec_hash "$layout_spec")"
jq --arg h "$layout_hash" '.specHash = $h' "$layout_spec" > "${TMPDIR}/layout-spec-hashed.json"
mv "${TMPDIR}/layout-spec-hashed.json" "$layout_spec"
bad_layout="${TMPDIR}/bad-layout"
mkdir -p "$bad_layout"
git -C "$bad_layout" init -q
git -C "$bad_layout" config commit.gpgsign false
git -C "$bad_layout" config user.email test@example.invalid
git -C "$bad_layout" config user.name contract
git -C "$bad_layout" commit -q --allow-empty -m empty
bad_sha="$(git -C "$bad_layout" rev-parse HEAD)"
bad_spec="${TMPDIR}/bad-layout-spec.json"
jq --arg sha "$bad_sha" '.sourceCommit = $sha | .config.orion.commit = $sha' "$FIXTURE" > "$bad_spec"
bad_hash="$(compute_spec_hash "$bad_spec")"
jq --arg h "$bad_hash" '.specHash = $h' "$bad_spec" > "${TMPDIR}/bad-layout-spec-hashed.json"
if "${ROOT_DIR}/scripts/build-android" --spec "${TMPDIR}/bad-layout-spec-hashed.json" --workspace "$bad_layout" --output-dir "${TMPDIR}/bad-out"; then
  log "unknown source layout was accepted"
  exit 1
fi
sub_root="${TMPDIR}/cosmos-layout"
sub_orion="${TMPDIR}/orion-sub"
mkdir -p "$sub_orion/apps/rigel/tool"
printf 'generator\n' > "$sub_orion/apps/rigel/tool/generate_release_build.dart"
git -C "$sub_orion" init -q
git -C "$sub_orion" config commit.gpgsign false
git -C "$sub_orion" config user.email test@example.invalid
git -C "$sub_orion" config user.name contract
git -C "$sub_orion" add .
git -C "$sub_orion" commit -q -m orion
orion_sha="$(git -C "$sub_orion" rev-parse HEAD)"
mkdir -p "$sub_root"
printf '[submodule "orion"]\n\tpath = orion\n\turl = https://github.com/prtmax/orion.git\n' > "$sub_root/.gitmodules"
git -C "$sub_root" init -q
git -C "$sub_root" config commit.gpgsign false
git -C "$sub_root" config user.email test@example.invalid
git -C "$sub_root" config user.name contract
git -C "$sub_root" add .gitmodules
git -C "$sub_root" commit -q -m cosmos
mkdir -p "$sub_root/orion"
git clone -q "$sub_orion" "$sub_root/orion"
cosmos_sha="$(git -C "$sub_root" rev-parse HEAD)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
resolved="$(resolve_release_app_dir "$sub_root" "$cosmos_sha" "$orion_sha")"
test "$resolved" = "$sub_root/orion/apps/rigel"
if ( resolve_release_app_dir "$layout_root" "$layout_sha" "1111111111111111111111111111111111111111" >/dev/null ); then
  log "direct orion checkout accepted a different orion commit"
  exit 1
fi
tool_bin="${TMPDIR}/buildbin"
mkdir -p "$tool_bin"
cat > "${tool_bin}/dart" <<'MOCKDART'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_DART_LOG:?}"
if [[ "${1:-}" != "run" || "${2:-}" != "tool/generate_release_build.dart" || $# -ne 5 ]]; then
  echo "generator requires SPEC OUTPUT_DIR RESOURCE_INDEX" >&2
  exit 2
fi
if [[ "${MOCK_GENERATOR_FAIL:-}" == "1" ]]; then
  exit 1
fi
python3 - "$3" "$4" "$5" "${MOCK_BAD_SETTINGS:-}" <<'PY'
import json, os, sys
from pathlib import Path
spec = json.loads(Path(sys.argv[1]).read_text())
out = Path(sys.argv[2])
index = json.loads(Path(sys.argv[3]).read_text())
if not index:
    raise SystemExit("resource index empty")
out.mkdir(parents=True, exist_ok=True)
env = spec["config"]["environment"]
app = spec["config"]["app"]
platform = spec["platform"]
identifier = app["applicationId"] if platform == "android" else app["bundleId"]
defines = {
    "APP_ENV": env["name"],
    "MERCURY_BASE_URL": env["mercuryBaseUrl"],
    "RUNTIME_BASE_URL": env["runtimeBaseUrl"],
    "RUNTIME_APP_BINDING": str(spec["appId"]),
    "RELEASE_CHANNEL": env["releaseChannel"],
}
bundled = json.dumps(spec["config"]["release"]["bundled"])
(out / "dart-defines.json").write_text(json.dumps(defines))
(out / "bundled.json").write_text(bundled)
(out / "platform-profiles.json").write_text(json.dumps({platform: {"applicationIdentifier": identifier, "targets": spec["targets"]}}))
settings = {
    "platform": platform,
    "applicationId": app["applicationId"],
    "bundleId": app["bundleId"],
    "displayName": app["displayName"],
    "versionName": app["versionName"],
    "versionCode": app["versionCode"],
}
if sys.argv[4] == "1":
    settings["applicationId"] = "com.example.tampered"
(out / "build-settings.json").write_text(json.dumps(settings))
overlay = out / "overlay"
(overlay / "assets" / "releases").mkdir(parents=True, exist_ok=True)
(overlay / "assets" / "releases" / "bundled.json").write_text(bundled)
(overlay / "marker.txt").write_text("frozen-overlay")
branded = overlay / "ios" / "Flutter"
branded.mkdir(parents=True, exist_ok=True)
(branded / "Branded.xcconfig").write_text(
    f"IOS_BUNDLE_ID={app['bundleId']}\nAPP_DISPLAY_NAME={app['displayName']}\n"
    f"FLUTTER_BUILD_NAME={app['versionName']}\nFLUTTER_BUILD_NUMBER={app['versionCode']}\n"
)
PY
MOCKDART
cat > "${tool_bin}/flutter" <<'MOCKFLUTTER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_FLUTTER_LOG:?}"
printf 'ENV ANDROID_APPLICATION_ID=%s\n' "${ANDROID_APPLICATION_ID-}" >> "${MOCK_FLUTTER_LOG}"
printf 'ENV APP_DISPLAY_NAME=%s\n' "${APP_DISPLAY_NAME-}" >> "${MOCK_FLUTTER_LOG}"
printf 'ENV IOS_BUNDLE_ID=%s\n' "${IOS_BUNDLE_ID-}" >> "${MOCK_FLUTTER_LOG}"
printf 'Flutter 3.47.2\n'
if [[ "$*" == *"build apk"* ]]; then
  mkdir -p build/app/outputs/flutter-apk
  printf 'apk-bytes' > build/app/outputs/flutter-apk/app-release.apk
fi
if [[ "$*" == *"build appbundle"* ]]; then
  mkdir -p build/app/outputs/bundle/release
  printf 'aab-bytes' > build/app/outputs/bundle/release/app-release.aab
fi
if [[ "$*" == *"build ios"* ]]; then
  if [[ ! -f ios/Flutter/Branded.xcconfig ]]; then
    echo "missing Branded.xcconfig" >&2
    exit 1
  fi
  mkdir -p build/ios/iphoneos/Runner.app/Frameworks/Demo.framework
  python3 - ios/Runner/Info.plist ios/Flutter/Branded.xcconfig build/ios/iphoneos/Runner.app/Info.plist "$@" <<'PY'
import plistlib, sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
branded = {}
for line in Path(sys.argv[2]).read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        key, value = line.split("=", 1)
        branded[key] = value
args = sys.argv[4:]
def flag(name):
    return args[args.index(name) + 1]
info["CFBundleIdentifier"] = branded["IOS_BUNDLE_ID"]
info["CFBundleDisplayName"] = branded["APP_DISPLAY_NAME"]
info["CFBundleShortVersionString"] = flag("--build-name")
info["CFBundleVersion"] = flag("--build-number")
Path(sys.argv[3]).write_bytes(plistlib.dumps(info))
PY
  printf 'framework' > build/ios/iphoneos/Runner.app/Frameworks/Demo.framework/Demo
  ln -sfn Demo build/ios/iphoneos/Runner.app/Frameworks/Demo.framework/DemoLink
  chmod 755 build/ios/iphoneos/Runner.app/Frameworks/Demo.framework/Demo
fi
MOCKFLUTTER
cat > "${tool_bin}/aapt" <<'MOCKAAPT'
#!/usr/bin/env bash
printf "%s\n" "package: name='com.example.contract' versionCode='7' versionName='1.2.3'"
MOCKAAPT
chmod +x "${tool_bin}/dart" "${tool_bin}/flutter" "${tool_bin}/aapt"
export RUNALL_FLUTTER="${tool_bin}/flutter"
export RUNALL_DART="${tool_bin}/dart"
export MOCK_DART_LOG="${TMPDIR}/dart.log"
export MOCK_FLUTTER_LOG="${TMPDIR}/flutter.log"
: > "$MOCK_DART_LOG"
: > "$MOCK_FLUTTER_LOG"
caller="${TMPDIR}/caller"
mkdir -p "$caller"
(
  cd "$caller"
  PATH="${tool_bin}:${PATH}" RUNALL_FROZEN_RESOURCE_ROOT="$layout_resources" "${ROOT_DIR}/scripts/build-android" \
    --spec "$layout_spec" --workspace "$layout_root" --output-dir rel-unsigned
)
test -f "${caller}/rel-unsigned/app-release.apk"
test ! -e "${ROOT_DIR}/rel-unsigned/app-release.apk"
test ! -e "${layout_root}/apps/rigel/rel-unsigned/app-release.apk"
grep -q 'tool/generate_release_build.dart' "$MOCK_DART_LOG"
grep -q 'resources.json' "$MOCK_DART_LOG"
grep -q -- '--dart-define-from-file' "$MOCK_FLUTTER_LOG"
grep -q 'ENV ANDROID_APPLICATION_ID=com.example.contract' "$MOCK_FLUTTER_LOG"
grep -q 'ENV APP_DISPLAY_NAME=Contract' "$MOCK_FLUTTER_LOG"
grep -q 'https://mercury.example.test' "${layout_root}/apps/rigel/.runall/release-build/dart-defines.json"
test "$(cat "${layout_root}/apps/rigel/marker.txt")" = "frozen-overlay"
aab_spec="${TMPDIR}/layout-aab-spec.json"
jq '.targets = ["aab"]' "$layout_spec" > "$aab_spec"
aab_hash="$(compute_spec_hash "$aab_spec")"
jq --arg h "$aab_hash" '.specHash = $h' "$aab_spec" > "${TMPDIR}/layout-aab-hashed.json"
mv "${TMPDIR}/layout-aab-hashed.json" "$aab_spec"
aab_caller="${TMPDIR}/aab-caller"
mkdir -p "$aab_caller"
(
  cd "$aab_caller"
  PATH="${tool_bin}:${PATH}" RUNALL_FROZEN_RESOURCE_ROOT="$layout_resources" "${ROOT_DIR}/scripts/build-android" \
    --spec "$aab_spec" --workspace "$layout_root" --output-dir rel-unsigned
)
test -f "${aab_caller}/rel-unsigned/app-release.aab"
test ! -e "${aab_caller}/rel-unsigned/app-release.apk"
python3 - "${layout_root}/apps/rigel/assets/releases/bundled.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("releaseId") != "14":
    raise SystemExit("bundled release was not deployed from the frozen spec")
PY
dart_lines="$(wc -l < "$MOCK_DART_LOG")"
bad_resources="${TMPDIR}/bad-resources"
mkdir -p "$bad_resources"
cp "$layout_resources/index.json" "$layout_resources/lang.ftl" "$bad_resources/"
printf 'tampered' > "$bad_resources/icon.bin"
if RUNALL_FROZEN_RESOURCE_ROOT="$bad_resources" PATH="${tool_bin}:${PATH}" "${ROOT_DIR}/scripts/build-android" \
  --spec "$layout_spec" --workspace "$layout_root" --output-dir "${TMPDIR}/bad-resource-out"; then
  log "resource digest mismatch was accepted"
  exit 1
fi
test ! -e "${TMPDIR}/bad-resource-out/app-release.apk"
test "$(wc -l < "$MOCK_DART_LOG")" = "$dart_lines"
url_index="${TMPDIR}/url-index.json"
jq --arg ref "$icon_ref" '.[$ref] = "https://evil.example/icon.bin"' "$layout_resources/index.json" > "$url_index"
if RUNALL_RESOURCE_INDEX="$url_index" RUNALL_FROZEN_RESOURCE_ROOT="$layout_resources" PATH="${tool_bin}:${PATH}" "${ROOT_DIR}/scripts/build-android" \
  --spec "$layout_spec" --workspace "$layout_root" --output-dir "${TMPDIR}/url-resource-out"; then
  log "external resource URL was accepted"
  exit 1
fi
test "$(wc -l < "$MOCK_DART_LOG")" = "$dart_lines"
abs_dir="${TMPDIR}/abs-resources"
mkdir -p "$abs_dir"
cp "$layout_resources/icon.bin" "$layout_resources/lang.ftl" "$abs_dir/"
python3 - "$abs_dir/index.json" "$icon_ref" "$lang_ref" "$abs_dir/icon.bin" "$abs_dir/lang.ftl" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({sys.argv[2]: sys.argv[4], sys.argv[3]: sys.argv[5]}) + "\n")
PY
abs_caller="${TMPDIR}/abs-caller"
mkdir -p "$abs_caller"
(
  cd "$abs_caller"
  PATH="${tool_bin}:${PATH}" RUNALL_RESOURCE_INDEX="$abs_dir/index.json" "${ROOT_DIR}/scripts/build-android" \
    --spec "$layout_spec" --workspace "$layout_root" --output-dir rel-unsigned
)
test -f "${abs_caller}/rel-unsigned/app-release.apk"
test "$(wc -l < "$MOCK_DART_LOG")" -gt "$dart_lines"
dart_lines="$(wc -l < "$MOCK_DART_LOG")"
escape_dir="${TMPDIR}/escape-resources"
mkdir -p "$escape_dir"
cp "$layout_resources/lang.ftl" "$escape_dir/"
python3 - "$escape_dir/index.json" "$icon_ref" "$lang_ref" "$layout_resources/icon.bin" "$escape_dir/lang.ftl" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({sys.argv[2]: sys.argv[4], sys.argv[3]: sys.argv[5]}) + "\n")
PY
if RUNALL_RESOURCE_INDEX="$escape_dir/index.json" PATH="${tool_bin}:${PATH}" "${ROOT_DIR}/scripts/build-android" \
  --spec "$layout_spec" --workspace "$layout_root" --output-dir "${TMPDIR}/escape-out"; then
  log "absolute resource path outside the index directory was accepted"
  exit 1
fi
test ! -e "${TMPDIR}/escape-out/app-release.apk"
test "$(wc -l < "$MOCK_DART_LOG")" = "$dart_lines"
python3 - "$abs_dir/index.json" "$icon_ref" "$lang_ref" "$abs_dir" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[4])
Path(sys.argv[1]).write_text(json.dumps({
    sys.argv[2]: str(root / ".." / "icon.bin"),
    sys.argv[3]: str(root / "lang.ftl"),
}) + "\n")
PY
if RUNALL_RESOURCE_INDEX="$abs_dir/index.json" PATH="${tool_bin}:${PATH}" "${ROOT_DIR}/scripts/build-android" \
  --spec "$layout_spec" --workspace "$layout_root" --output-dir "${TMPDIR}/dotdot-out"; then
  log "parent segment in an absolute resource path was accepted"
  exit 1
fi
test "$(wc -l < "$MOCK_DART_LOG")" = "$dart_lines"
ln -s icon.bin "$abs_dir/icon-link.bin"
python3 - "$abs_dir/index.json" "$icon_ref" "$lang_ref" "$abs_dir/icon-link.bin" "$abs_dir/lang.ftl" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({sys.argv[2]: sys.argv[4], sys.argv[3]: sys.argv[5]}) + "\n")
PY
if RUNALL_RESOURCE_INDEX="$abs_dir/index.json" PATH="${tool_bin}:${PATH}" "${ROOT_DIR}/scripts/build-android" \
  --spec "$layout_spec" --workspace "$layout_root" --output-dir "${TMPDIR}/symlink-out"; then
  log "symlinked frozen resource was accepted"
  exit 1
fi
test "$(wc -l < "$MOCK_DART_LOG")" = "$dart_lines"
staged_resources="${TMPDIR}/staged-resources"
python3 - "$abs_dir/index.json" "$icon_ref" "$lang_ref" "$abs_dir/icon.bin" "$abs_dir/lang.ftl" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({sys.argv[2]: sys.argv[4], sys.argv[3]: sys.argv[5]}) + "\n")
PY
"${ROOT_DIR}/scripts/stage-frozen-resources" --spec "$layout_spec" --index "$abs_dir/index.json" --output "$staged_resources"
python3 - "$staged_resources/index.json" <<'PY'
import json, sys
from pathlib import Path
mapping = json.loads(Path(sys.argv[1]).read_text())
if not mapping or any(value.startswith("/") or "://" in value or ".." in value for value in mapping.values()):
    raise SystemExit("staged index did not use relative paths")
for value in mapping.values():
    if not (Path(sys.argv[1]).parent / value).is_file():
        raise SystemExit("staged resource file missing")
PY
handoff_caller="${TMPDIR}/handoff-caller"
mkdir -p "$handoff_caller"
(
  cd "$handoff_caller"
  PATH="${tool_bin}:${PATH}" RUNALL_FROZEN_RESOURCE_ROOT="$staged_resources" "${ROOT_DIR}/scripts/build-android" \
    --spec "$layout_spec" --workspace "$layout_root" --output-dir "${PWD}/unsigned"
)
test -f "${handoff_caller}/unsigned/app-release.apk"
test ! -e "${ROOT_DIR}/unsigned/app-release.apk"
if "${ROOT_DIR}/scripts/stage-frozen-resources" --spec "$layout_spec" --output "${TMPDIR}/missing-stage" >/dev/null 2>&1; then
  log "missing authorized resource index was staged"
  exit 1
fi
if MOCK_BAD_SETTINGS=1 RUNALL_FROZEN_RESOURCE_ROOT="$layout_resources" PATH="${tool_bin}:${PATH}" "${ROOT_DIR}/scripts/build-android" \
  --spec "$layout_spec" --workspace "$layout_root" --output-dir "${TMPDIR}/bad-settings-out"; then
  log "tampered build-settings were accepted"
  exit 1
fi
unset MOCK_BAD_SETTINGS
: > "$MOCK_FLUTTER_LOG"
ios_spec="${TMPDIR}/layout-ios-spec.json"
jq '.platform = "ios" | .targets = ["ipa"]' "$layout_spec" > "$ios_spec"
ios_layout_hash="$(compute_spec_hash "$ios_spec")"
jq --arg h "$ios_layout_hash" '.specHash = $h' "$ios_spec" > "${TMPDIR}/layout-ios-hashed.json"
mv "${TMPDIR}/layout-ios-hashed.json" "$ios_spec"
ios_caller="${TMPDIR}/ios-caller"
mkdir -p "$ios_caller"
(
  cd "$ios_caller"
  PATH="${tool_bin}:${PATH}" RUNALL_FROZEN_RESOURCE_ROOT="$layout_resources" "${ROOT_DIR}/scripts/build-ios" \
    --spec "$ios_spec" --workspace "$layout_root" --output-dir rel-unsigned
)
test -f "${ios_caller}/rel-unsigned/Runner.app.tar"
test ! -d "${ios_caller}/rel-unsigned/Runner.app"
mkdir -p "${TMPDIR}/ios-roundtrip"
tar -xf "${ios_caller}/rel-unsigned/Runner.app.tar" -C "${TMPDIR}/ios-roundtrip"
test -L "${TMPDIR}/ios-roundtrip/Runner.app/Frameworks/Demo.framework/DemoLink"
test "$(stat -c '%a' "${TMPDIR}/ios-roundtrip/Runner.app/Frameworks/Demo.framework/Demo")" = "755"
grep -q -- '--no-codesign' "$MOCK_FLUTTER_LOG"
grep -q -- '--build-name 1.2.3' "$MOCK_FLUTTER_LOG"
python3 - "${layout_root}/apps/rigel/ios/Flutter/Release.xcconfig" "${layout_root}/apps/rigel/ios/Flutter/Branded.xcconfig" "${layout_root}/apps/rigel/ios/Runner/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
release, branded, info_path = map(Path, sys.argv[1:])
if release.read_text() != "IOS_BUNDLE_ID=com.aiyin.rigel\n":
    raise SystemExit("Release.xcconfig was rewritten instead of using the overlay")
text = branded.read_text()
if "IOS_BUNDLE_ID=com.example.contract\n" not in text or "APP_DISPLAY_NAME=Contract\n" not in text:
    raise SystemExit("frozen Branded.xcconfig was not applied")
info = plistlib.loads(info_path.read_bytes())
if info.get("CFBundleDisplayName") != "Rigel":
    raise SystemExit("Info.plist display name was hardcoded")
PY
grep -q 'ENV IOS_BUNDLE_ID=com.example.contract' "$MOCK_FLUTTER_LOG"
grep -q 'ENV APP_DISPLAY_NAME=Contract' "$MOCK_FLUTTER_LOG"

log "contract: upload rejects a mismatched grant, failed PUT, and failed complete"
upload_cases="${TMPDIR}/upload-cases"
mkdir -p "$upload_cases"
printf 'apk-bytes' > "${upload_cases}/app.apk"
printf 'aab-bytes' > "${upload_cases}/app.aab"
printf 'ipa-bytes' > "${upload_cases}/app.ipa"
cat > "${upload_cases}/curl" <<'MOCKUP'
#!/usr/bin/env bash
joined="$*"
data=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--data-binary" ]]; then data="$arg"; fi
  prev="$arg"
done
mode="${MOCK_UPLOAD_MODE:?}"
if [[ "$joined" == *" -X PUT "* || "$joined" == *" -X PUT" ]]; then
  if [[ "$mode" == "put-fail" ]]; then exit 1; fi
  printf 'put %s\n' "$joined" >> "${MOCK_UPLOAD_LOG:?}"
  exit 0
fi
if [[ "$joined" == *"/complete"* ]]; then
  if [[ "$mode" == "complete-fail" ]]; then exit 1; fi
  printf '%s\n' "$data" >> "${MOCK_UPLOAD_LOG:?}"
  printf '{}\n'
  exit 0
fi
if [[ -n "$data" ]]; then
  size=$(wc -c < "${MOCK_UPLOAD_ARTIFACT:?}" | tr -d ' ')
  digest=$(sha256sum "${MOCK_UPLOAD_ARTIFACT}" | awk '{print $1}')
  name=$(basename "${MOCK_UPLOAD_ARTIFACT}")
  target="${MOCK_UPLOAD_TARGET:?}"
  if [[ "$target" == "apk" ]]; then ctype="application/vnd.android.package-archive"; else ctype="application/octet-stream"; fi
  key="builds/contract/${target}/${digest}/${name}"
  url="https://uploads.example.test/object"
  if [[ "$mode" == "bad-grant" ]]; then digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; fi
  if [[ "$mode" == "bad-url" ]]; then url="http://uploads.example.test/object"; fi
  printf '{"url":"%s","method":"PUT","objectKey":"%s","fileName":"%s","contentType":"%s","byteSize":%s,"sha256":"%s","target":"%s","headers":{}}\n' "$url" "$key" "$name" "$ctype" "$size" "$digest" "$target"
  exit 0
fi
exit 1
MOCKUP
chmod +x "${upload_cases}/curl"
for target in apk aab ipa; do
  spec_for="$layout_spec"
  if [[ "$target" == "aab" ]]; then
    spec_for="${TMPDIR}/aab-upload-spec.json"
    jq '.targets = ["aab"]' "$layout_spec" > "$spec_for"
    h="$(compute_spec_hash "$spec_for")"
    jq --arg hash "$h" '.specHash = $hash' "$spec_for" > "${spec_for}.hashed"
    mv "${spec_for}.hashed" "$spec_for"
  elif [[ "$target" == "ipa" ]]; then
    spec_for="$ios_spec"
  fi
  : > "${TMPDIR}/case.log"
  PATH="${upload_cases}:${PATH}" \
    MOCK_UPLOAD_MODE=ok \
    MOCK_UPLOAD_LOG="${TMPDIR}/case.log" \
    MOCK_UPLOAD_ARTIFACT="${upload_cases}/app.${target}" \
    MOCK_UPLOAD_TARGET="$target" \
    COSMOS_BUILD_ARTIFACT_UPLOAD_URL="https://example.test/internal" \
    COSMOS_BUILD_CREDENTIAL="test-credential" \
    BUILD_RUN_ID="run-contract-test" \
    "${ROOT_DIR}/scripts/upload-artifacts" --spec "$spec_for" --artifact "${upload_cases}/app.${target}" --target "$target"
  grep -q '"target": "'"$target"'"' "${TMPDIR}/case.log"
  if [[ "$target" != "apk" ]]; then
    grep -q 'application/octet-stream' "${TMPDIR}/case.log"
  fi
done
if PATH="${upload_cases}:${PATH}" MOCK_UPLOAD_MODE=bad-grant MOCK_UPLOAD_LOG="${TMPDIR}/case.log" MOCK_UPLOAD_ARTIFACT="${upload_cases}/app.apk" MOCK_UPLOAD_TARGET=apk COSMOS_BUILD_ARTIFACT_UPLOAD_URL="https://example.test/internal" COSMOS_BUILD_CREDENTIAL="test-credential" BUILD_RUN_ID="run-contract-test" "${ROOT_DIR}/scripts/upload-artifacts" --spec "$layout_spec" --artifact "${upload_cases}/app.apk" --target apk; then
  log "inconsistent upload grant was accepted"
  exit 1
fi
if PATH="${upload_cases}:${PATH}" MOCK_UPLOAD_MODE=bad-url MOCK_UPLOAD_LOG="${TMPDIR}/case.log" MOCK_UPLOAD_ARTIFACT="${upload_cases}/app.apk" MOCK_UPLOAD_TARGET=apk COSMOS_BUILD_ARTIFACT_UPLOAD_URL="https://example.test/internal" COSMOS_BUILD_CREDENTIAL="test-credential" BUILD_RUN_ID="run-contract-test" "${ROOT_DIR}/scripts/upload-artifacts" --spec "$layout_spec" --artifact "${upload_cases}/app.apk" --target apk; then
  log "non-https upload URL was accepted"
  exit 1
fi
: > "${TMPDIR}/case.log"
if PATH="${upload_cases}:${PATH}" MOCK_UPLOAD_MODE=put-fail MOCK_UPLOAD_LOG="${TMPDIR}/case.log" MOCK_UPLOAD_ARTIFACT="${upload_cases}/app.apk" MOCK_UPLOAD_TARGET=apk COSMOS_BUILD_ARTIFACT_UPLOAD_URL="https://example.test/internal" COSMOS_BUILD_CREDENTIAL="test-credential" BUILD_RUN_ID="run-contract-test" "${ROOT_DIR}/scripts/upload-artifacts" --spec "$layout_spec" --artifact "${upload_cases}/app.apk" --target apk; then
  log "PUT failure was reported as success"
  exit 1
fi
if grep -q '/complete' "${TMPDIR}/case.log"; then
  log "complete ran after PUT failure"
  exit 1
fi
if PATH="${upload_cases}:${PATH}" MOCK_UPLOAD_MODE=complete-fail MOCK_UPLOAD_LOG="${TMPDIR}/case.log" MOCK_UPLOAD_ARTIFACT="${upload_cases}/app.apk" MOCK_UPLOAD_TARGET=apk COSMOS_BUILD_ARTIFACT_UPLOAD_URL="https://example.test/internal" COSMOS_BUILD_CREDENTIAL="test-credential" BUILD_RUN_ID="run-contract-test" "${ROOT_DIR}/scripts/upload-artifacts" --spec "$layout_spec" --artifact "${upload_cases}/app.apk" --target apk; then
  log "complete failure was reported as success"
  exit 1
fi

log "contract: sensitive workflows are pinned to an immutable SHA"
# Default pull_request checkout is depth-1, so ancestor pin commits are absent and
# `git show <pin>:<path>` fails even though the workflow file exists at HEAD.
# Prove each pin from checked-in commit objects and tree listings instead.
SHALLOW="${TMPDIR}/depth1-checkout"
git init -q "${SHALLOW}"
git -C "${SHALLOW}" fetch --depth 1 "file://${ROOT_DIR}" HEAD
git -C "${SHALLOW}" checkout -q --detach FETCH_HEAD
if [[ "$(git -C "${SHALLOW}" rev-parse --is-shallow-repository)" != "true" ]]; then
  log "expected the pin proof to run against a depth-1 checkout"
  exit 1
fi
python3 - "${ROOT_DIR}" "${SHALLOW}" <<'PY'
import pathlib, subprocess, sys

root = pathlib.Path(sys.argv[1])
shallow = pathlib.Path(sys.argv[2])
fixdir = root / "scripts/tests/fixtures/workflow-pins"
text = (root / ".github/workflows/android-build.yml").read_text()
names = [
    "reusable-prepare.yml",
    "reusable-sign-android.yml",
    "reusable-finalize-android.yml",
    "reusable-sign-ios.yml",
    "reusable-finalize-ios.yml",
]

def git_hash(kind, payload):
    proc = subprocess.run(
        ["git", "-C", str(root), "hash-object", "-t", kind, "--stdin"],
        input=payload,
        stdout=subprocess.PIPE,
        check=True,
    )
    return proc.stdout.decode().strip()

def tree_payload(ls_text):
    entries = []
    for line in ls_text.splitlines():
        if not line.strip():
            continue
        meta, name = line.split("\t", 1)
        mode, _typ, sha = meta.split(" ")
        # ls-tree prints 040000; the tree object stores 40000.
        if mode == "040000":
            mode = "40000"
        entries.append((name, mode, bytes.fromhex(sha)))
    entries.sort(key=lambda item: item[0] + ("/" if item[1] == "40000" else ""))
    body = b""
    for name, mode, sha in entries:
        body += f"{mode} {name}".encode() + b"\0" + sha
    return body

def tree_entry(ls_text, wanted):
    for line in ls_text.splitlines():
        meta, name = line.split("\t", 1)
        _mode, typ, sha = meta.split(" ")
        if name == wanted:
            return typ, sha
    raise SystemExit(f"{wanted} missing from tree listing")

for name in names:
    marker = f"prtmax/runall/.github/workflows/{name}@"
    if marker not in text:
        raise SystemExit(f"missing SHA pin for {name}")
    sha = text.split(marker, 1)[1].splitlines()[0].strip()
    if len(sha) != 40 or any(ch not in "0123456789abcdef" for ch in sha):
        raise SystemExit(f"pin for {name} is not a full SHA: {sha}")

    shown = subprocess.run(
        ["git", "-C", str(shallow), "show", f"{sha}:.github/workflows/{name}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if shown.returncode == 0:
        raise SystemExit(f"depth-1 checkout unexpectedly contained pin {sha}")
    err = shown.stderr.decode(errors="replace")
    if "exists on disk, but not in" not in err:
        raise SystemExit(f"depth-1 pin lookup for {name} did not fail closed: {err}")

    commit_path = fixdir / f"{sha}.commit"
    if not commit_path.is_file():
        raise SystemExit(f"missing commit fixture for {sha}")
    commit = commit_path.read_bytes()
    if git_hash("commit", commit) != sha:
        raise SystemExit(f"commit fixture for {name} does not hash to {sha}")
    local = subprocess.run(
        ["git", "-C", str(root), "cat-file", "commit", sha],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if local.returncode == 0 and local.stdout != commit:
        raise SystemExit(f"commit fixture for {sha} does not match the local object")

    header = commit.splitlines()[0]
    if not header.startswith(b"tree "):
        raise SystemExit(f"commit fixture {sha} has no tree")
    tree_sha = header.split()[1].decode()
    for part in (".github", "workflows", name):
        listing_path = fixdir / f"{tree_sha}.ls-tree"
        if not listing_path.is_file():
            raise SystemExit(f"missing tree fixture {tree_sha} for {name}")
        listing = listing_path.read_text()
        if git_hash("tree", tree_payload(listing)) != tree_sha:
            raise SystemExit(f"tree fixture {tree_sha} does not hash to its name")
        typ, found = tree_entry(listing, part)
        if part == name:
            if typ != "blob":
                raise SystemExit(f"pinned {name} is not a blob")
            blob_sha = found
        else:
            if typ != "tree":
                raise SystemExit(f"{part} is not a tree while resolving {name}")
            tree_sha = found

    current = (root / ".github/workflows" / name).read_bytes()
    checked_out = (shallow / ".github/workflows" / name).read_bytes()
    if checked_out != current:
        raise SystemExit(f"depth-1 copy of {name} differs from HEAD")
    if git_hash("blob", current) != blob_sha:
        raise SystemExit(f"pinned {name} does not match the file at HEAD")
PY

if [[ -n "${ORION_ROOT:-}" && -n "${COSMOS_ROOT:-}" ]]; then
  log "contract: cross-repo frozen generator and Mercury schema"
  ORION_ROOT="$ORION_ROOT" COSMOS_ROOT="$COSMOS_ROOT" "${ROOT_DIR}/scripts/tests/cross-repo-contract.sh"
fi

log "all contract tests passed"
