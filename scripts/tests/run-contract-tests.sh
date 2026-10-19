#!/usr/bin/env bash
# Offline contract tests for the native Flutter executor.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/runall-native-contract-XXXXXX")"

fixture="${ROOT_DIR}/scripts/tests/fixtures/android-apk-spec.json"
input_digest="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" input "$fixture")"
jq --arg digest "$input_digest" '.inputDigest = $digest' "$fixture" > "$work/input.json"
spec_digest="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" spec "$work/input.json")"
jq --arg digest "$spec_digest" '.specDigest = $digest' "$work/input.json" > "$work/spec.json"

BUILD_SPEC_FILE="$work/spec.json" "${ROOT_DIR}/scripts/load-build-spec" --output "$work/out.json" --run-id 900

jq '.buildInput.app.displayName = "tampered"' "$work/spec.json" > "$work/tampered.json"
if BUILD_SPEC_FILE="$work/tampered.json" "${ROOT_DIR}/scripts/load-build-spec" --output "$work/out.json" 2>/dev/null; then
  log "tampered native build input was accepted"
  exit 1
fi

jq '.targets = ["ipa"]' "$work/spec.json" > "$work/tampered.json"
if BUILD_SPEC_FILE="$work/tampered.json" "${ROOT_DIR}/scripts/load-build-spec" --output "$work/out.json" 2>/dev/null; then
  log "invalid Android targets were accepted"
  exit 1
fi

if [[ -n "${COSMOS_ROOT:-}" ]]; then
  vector="${COSMOS_ROOT}/fornax/dalim/fixtures/native/canonical-vectors.json"
  jq '{buildInput:(.[] | select(.kind == "build") | .normalized)}' "$vector" > "$work/vector.json"
  expected="$(jq -r '.[] | select(.kind == "build") | .digest' "$vector")"
  actual="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" input "$work/vector.json")"
  [[ "$actual" == "$expected" ]] || { log "RFC 8785 build vector mismatch"; exit 1; }
fi

printf '{"buildInput":{"tokens":{"one":1e-7,"large":1e30,"astral":"😀","bmp":"�"}}}\n' > "$work/jcs.json"
number_digest="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" input "$work/jcs.json")"
expected_number_digest="$(printf '%s' '{"tokens":{"astral":"😀","bmp":"�","large":1e+30,"one":1e-7}}' | sha256sum | awk '{print $1}')"
[[ "$number_digest" == "$expected_number_digest" ]] || { log "JCS number or UTF-16 ordering drifted"; exit 1; }

log "contract: build source is pinned to reviewed Orion authority"
[[ "$(source_origin_url prtmax/orion)" == "https://github.com/prtmax/orion.git" ]]
[[ "$(source_origin_url https://github.com/prtmax/orion.git)" == "https://github.com/prtmax/orion.git" ]]
if (source_origin_url prtmax/unreviewed) >/dev/null 2>&1; then
  log "untrusted source repository was accepted"
  exit 1
fi
jq '.buildInput.source.repository = "attacker/orion"' "$work/spec.json" > "$work/untrusted.json"
if BUILD_SPEC_FILE="$work/untrusted.json" "${ROOT_DIR}/scripts/load-build-spec" --output "$work/out.json" 2>/dev/null; then
  log "build spec selected an arbitrary executable repository"
  exit 1
fi
grep -q 'refs/heads/main:refs/remotes/origin/main' "${ROOT_DIR}/scripts/checkout-source"
grep -q 'merge-base --is-ancestor' "${ROOT_DIR}/scripts/checkout-source"
if grep -q 'fetch --depth=1 origin.*source_commit' "${ROOT_DIR}/scripts/checkout-source"; then
  log "checkout can still fetch a payload-selected unreviewed commit"
  exit 1
fi
log "contract: checkout requires trusted main ancestry before executing source"
mkdir -p "$work/git-bin"
printf 'locked\n' > "$work/mock-lock"
lock_digest="$(sha256_file "$work/mock-lock")"
jq --arg digest "$lock_digest" '.buildInput.source.lockDigest=$digest' "$work/spec.json" > "$work/checkout-raw.json"
checkout_input="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" input "$work/checkout-raw.json")"
jq --arg digest "$checkout_input" '.inputDigest=$digest' "$work/checkout-raw.json" > "$work/checkout-input.json"
checkout_digest="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" spec "$work/checkout-input.json")"
jq --arg digest "$checkout_digest" '.specDigest=$digest' "$work/checkout-input.json" > "$work/checkout-spec.json"
cat > "$work/git-bin/git" <<'MOCKGIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_GIT_LOG:?}"
if [[ "$1" == "-c" ]]; then shift 2; fi
if [[ "$1" == "init" ]]; then mkdir -p "$2/.git"; exit 0; fi
if [[ "$1" == "-C" ]]; then
  root="$2"; shift 2
  case "$1 $2" in
    "remote get-url") printf 'https://github.com/prtmax/orion.git\n'; exit 0 ;;
    "cat-file -e") [[ "${MOCK_TRUSTED:-}" == 1 ]]; exit ;;
    "merge-base --is-ancestor") [[ "${MOCK_TRUSTED:-}" == 1 ]]; exit ;;
    "checkout --detach")
      mkdir -p "$root/tools/app_assembler" "$root/apps/rigel"
      printf 'assembler\n' > "$root/tools/app_assembler/assemble.py"
      cp "${MOCK_LOCK:?}" "$root/pubspec.lock"
      exit 0
      ;;
    "rev-parse HEAD") printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; exit 0 ;;
  esac
  exit 0
fi
exit 0
MOCKGIT
chmod +x "$work/git-bin/git"
: > "$work/git.log"
MOCK_TRUSTED=1 MOCK_LOCK="$work/mock-lock" MOCK_GIT_LOG="$work/git.log" PATH="$work/git-bin:$PATH" \
  COSMOS_BUILD_REPOSITORY_TOKEN=secret-token "${ROOT_DIR}/scripts/checkout-source" \
  --spec "$work/checkout-spec.json" --workspace "$work/trusted-source"
grep -q 'refs/heads/main:refs/remotes/origin/main' "$work/git.log"
grep -q 'merge-base --is-ancestor' "$work/git.log"
if grep -q 'secret-token@' "$work/git.log"; then
  log "repository token was embedded in the remote URL"
  exit 1
fi
if MOCK_TRUSTED=0 MOCK_LOCK="$work/mock-lock" MOCK_GIT_LOG="$work/git.log" PATH="$work/git-bin:$PATH" \
  "${ROOT_DIR}/scripts/checkout-source" --spec "$work/checkout-spec.json" \
  --workspace "$work/unreviewed-source" >/dev/null 2>&1; then
  log "commit outside trusted Orion main history was checked out"
  exit 1
fi

log "contract: OIDC exchange sends run-bound token and persists only stage credential"
mock_bin="$work/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--data-binary" ]]; then
    printf '%s\n' "$2" > "${MOCK_PAYLOAD:?}"
    printf '{"accessToken":"stage-token"}\n'
    exit 0
  fi
  shift
done
exit 1
MOCK
chmod +x "$mock_bin/curl"
MOCK_PAYLOAD="$work/exchange.json" COSMOS_BUILD_AUTH_EXCHANGE_URL=https://api.example.test/exchange \
  COSMOS_BUILD_OIDC_TOKEN=github-oidc BUILD_RUN_ID=900 PATH="$mock_bin:$PATH" \
  "${ROOT_DIR}/scripts/exchange-build-credential" --run-id 900 --output-env "$work/stage.env"
jq -e '.runId == "900" and .githubOidcToken == "github-oidc"' "$work/exchange.json" >/dev/null
grep -qx 'COSMOS_BUILD_CREDENTIAL=stage-token' "$work/stage.env"
if grep -q 'github-oidc' "$work/stage.env"; then
  log "OIDC token leaked to the job environment"
  exit 1
fi

log "contract: callback and artifact upload remain run-bound and fail closed"
cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
joined="$*"
data=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--data-binary" ]]; then data="$arg"; fi
  prev="$arg"
done
if [[ "$joined" == *"/events"* ]]; then
  printf '%s\n' "$data" > "${MOCK_EVENT_PAYLOAD:?}"
  exit 0
fi
if [[ "$joined" == *" -X PUT "* || "$joined" == *" -X PUT" ]]; then
  [[ "${MOCK_UPLOAD_MODE:-ok}" == "put-fail" ]] && exit 1
  printf 'put\n' >> "${MOCK_UPLOAD_LOG:?}"
  exit 0
fi
if [[ "$joined" == *"/complete"* ]]; then
  printf '%s\n' "$data" >> "${MOCK_UPLOAD_LOG:?}"
  printf '{}\n'
  exit 0
fi
if [[ "$joined" == *"artifact-uploads"* ]]; then
  printf '%s\n' "$data" > "${MOCK_UPLOAD_REQUEST:?}"
  size=$(wc -c < "${MOCK_UPLOAD_ARTIFACT:?}" | tr -d ' ')
  digest=$(sha256sum "${MOCK_UPLOAD_ARTIFACT:?}" | awk '{print $1}')
  url="https://uploads.example.test/object"
  [[ "${MOCK_UPLOAD_MODE:-ok}" == "bad-url" ]] && url="http://uploads.example.test/object"
  printf '{"url":"%s","method":"PUT","objectKey":"native/900/apk","fileName":"app.apk","contentType":"application/vnd.android.package-archive","byteSize":%s,"sha256":"%s","target":"apk","headers":{}}\n' "$url" "$size" "$digest"
  exit 0
fi
exit 1
MOCK
chmod +x "$mock_bin/curl"
: > "$work/upload.log"
printf 'apk-bytes' > "$work/app.apk"
MOCK_EVENT_PAYLOAD="$work/event.json" PATH="$mock_bin:$PATH" COSMOS_BUILD_CALLBACK_URL=https://api.example.test/internal \
  COSMOS_BUILD_CREDENTIAL=stage-token BUILD_RUN_ID=900 GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 \
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=prtmax/runall \
  "${ROOT_DIR}/scripts/report-result" --status running --phase prepare --run-id 900
jq -e '.status=="running" and .phase=="prepare" and .externalRunId=="123"' "$work/event.json" >/dev/null
MOCK_UPLOAD_LOG="$work/upload.log" MOCK_UPLOAD_REQUEST="$work/upload-request.json" MOCK_UPLOAD_ARTIFACT="$work/app.apk" \
  PATH="$mock_bin:$PATH" COSMOS_BUILD_ARTIFACT_UPLOAD_URL=https://api.example.test/internal \
  COSMOS_BUILD_CREDENTIAL=finalize-token BUILD_RUN_ID=900 \
  "${ROOT_DIR}/scripts/upload-artifacts" --spec "$work/spec.json" --artifact "$work/app.apk" --target apk
jq -e '.target=="apk" and .fileName=="app.apk" and .byteSize>0 and (.sha256|test("^[0-9a-f]{64}$"))' "$work/upload-request.json" >/dev/null
grep -q '^put$' "$work/upload.log"
if MOCK_UPLOAD_MODE=bad-url MOCK_UPLOAD_LOG="$work/upload.log" MOCK_UPLOAD_REQUEST="$work/upload-request.json" MOCK_UPLOAD_ARTIFACT="$work/app.apk" \
  PATH="$mock_bin:$PATH" COSMOS_BUILD_ARTIFACT_UPLOAD_URL=https://api.example.test/internal \
  COSMOS_BUILD_CREDENTIAL=finalize-token BUILD_RUN_ID=900 \
  "${ROOT_DIR}/scripts/upload-artifacts" --spec "$work/spec.json" --artifact "$work/app.apk" --target apk >/dev/null 2>&1; then
  log "non-HTTPS artifact grant was accepted"
  exit 1
fi

log "contract: frozen packaging response is exact, bounded, and digest verified"
mkdir -p "$work/packaging"
printf 'png-bytes' > "$work/packaging/icon.png"
resource_digest="$(sha256_file "$work/packaging/icon.png")"
jq --arg digest "$resource_digest" '.buildInput.resources = [{kind:"app_icon",key:"app_icon",ref:"app-studio/icon/1",digest:$digest,contentType:"image/png"}]' "$work/spec.json" > "$work/resource-raw.json"
resource_input="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" input "$work/resource-raw.json")"
jq --arg digest "$resource_input" '.inputDigest=$digest' "$work/resource-raw.json" > "$work/resource-input.json"
resource_spec="$(node "${ROOT_DIR}/scripts/lib/native_digest.js" spec "$work/resource-input.json")"
jq --arg digest "$resource_spec" '.specDigest=$digest' "$work/resource-input.json" > "$work/resource-spec.json"
base64 -w0 "$work/packaging/icon.png" > "$work/packaging/icon.base64"
jq -n --arg digest "$resource_digest" --rawfile content "$work/packaging/icon.base64" '[{ref:"app-studio/icon/1",digest:$digest,contentType:"image/png",contentBase64:$content}]' > "$work/packaging/response.json"
COSMOS_BUILD_PACKAGING_RESOURCES_FILE="$work/packaging/response.json" \
  "${ROOT_DIR}/scripts/fetch-packaging-resources" --spec "$work/resource-spec.json" --output "$work/packaging/output"
"${ROOT_DIR}/scripts/stage-frozen-resources" --spec "$work/resource-spec.json" \
  --index "$work/packaging/output/index.json" --output "$work/packaging/staged"
printf 'tampered' > "$work/packaging/tampered.bin"
base64 -w0 "$work/packaging/tampered.bin" > "$work/packaging/tampered.base64"
jq --rawfile content "$work/packaging/tampered.base64" '.[0].contentBase64=$content' "$work/packaging/response.json" > "$work/packaging/bad.json"
if COSMOS_BUILD_PACKAGING_RESOURCES_FILE="$work/packaging/bad.json" \
  "${ROOT_DIR}/scripts/fetch-packaging-resources" --spec "$work/resource-spec.json" --output "$work/packaging/rejected" >/dev/null 2>&1; then
  log "packaging bytes with a mismatched digest were accepted"
  exit 1
fi
jq '.[0].password="secret"' "$work/packaging/response.json" > "$work/packaging/extra.json"
if COSMOS_BUILD_PACKAGING_RESOURCES_FILE="$work/packaging/extra.json" \
  "${ROOT_DIR}/scripts/fetch-packaging-resources" --spec "$work/resource-spec.json" --output "$work/packaging/extra-output" >/dev/null 2>&1; then
  log "unexpected packaging response field was accepted"
  exit 1
fi

log "contract: signing identity comes from immutable native input"
[[ "$(read_app_version_code "$work/spec.json")" == 1 ]]
jq '.buildInput.app.versionCode="1"' "$work/spec.json" > "$work/string-version.json"
if (read_app_version_code "$work/string-version.json") >/dev/null 2>&1; then
  log "string versionCode was accepted for signing"
  exit 1
fi
if (require_sign_receipt_fields com.example.native 1.0.0 1 invalid) >/dev/null 2>&1; then
  log "invalid signing certificate digest was accepted"
  exit 1
fi
for script in sign-android sign-aab sign-ios; do
  grep -q '\.buildInput\.app' "${ROOT_DIR}/scripts/$script"
  grep -q 'report_sign_result' "${ROOT_DIR}/scripts/$script"
done

log "contract: compile stages remain uncredentialed and signing/finalize stay isolated"
python3 - "${ROOT_DIR}/.github/workflows/android-build.yml" "${ROOT_DIR}/.github/workflows/reusable-prepare.yml" <<'PY'
from pathlib import Path
import sys
workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
def job(start, end):
    body = workflow.split(f"  {start}:\n", 1)[1]
    return body.split(f"\n  {end}:\n", 1)[0]
android = job("build-android", "sign-android")
ios = job("build-ios", "sign-ios")
for name, body in (("android", android), ("ios", ios)):
    for forbidden in ("id-token: write", "COSMOS_BUILD_CREDENTIAL", "COSMOS_BUILD_REPOSITORY_TOKEN", "COSMOS_BUILD_SIGN_MATERIAL_URL", "COSMOS_BUILD_SPEC_URL"):
        if forbidden in body:
            raise SystemExit(f"{name} compile stage contains {forbidden}")
    if "contents: read" not in body or "RUNALL_FROZEN_RESOURCE_ROOT" not in body:
        raise SystemExit(f"{name} compile stage lost its frozen unprivileged boundary")
prepare = Path(sys.argv[2]).read_text(encoding="utf-8")
for required in ("id-token: write", "exchange-build-credential", "fetch-packaging-resources", "checkout-source"):
    if required not in prepare:
        raise SystemExit(f"prepare stage missing {required}")
for required in ("reusable-sign-android.yml", "reusable-sign-ios.yml", "reusable-finalize-android.yml", "reusable-finalize-ios.yml"):
    if required not in workflow:
        raise SystemExit(f"workflow missing isolated stage {required}")
PY
if grep -q 'COSMOS_BUILD_REPOSITORY_TOKEN\|COSMOS_BUILD_CREDENTIAL\|id-token' "${ROOT_DIR}/scripts/build-android" "${ROOT_DIR}/scripts/build-ios"; then
  log "compile script references a privileged credential"
  exit 1
fi

if rg -n 'cosmos\.release-build\.v1|generate_release_build|bundled\.json' \
  "${ROOT_DIR}/scripts" "${ROOT_DIR}/.github" "${ROOT_DIR}/README.md" \
  -g '!run-contract-tests.sh'; then
  log "legacy Release Build protocol remains in active executor paths"
  exit 1
fi

log "native executor contract tests passed"
