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
jq '.config.android.applicationId = "com.example.tampered"' "$FIXTURE" > "$tampered"
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
touch "${TMPDIR}/fake.apk"
export COSMOS_BUILD_ARTIFACT_UPLOAD_URL="https://example.test/internal"
export COSMOS_BUILD_CREDENTIAL="test-credential"
export BUILD_RUN_ID="run-contract-test"
cat > "${mock_bin2}/curl" <<'MOCK3'
#!/usr/bin/env bash
if [[ "${1:-}" == "--fail-with-body" ]]; then
  shift
fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--data-binary" ]]; then
    echo "$2" > "${MOCK_UPLOAD_PAYLOAD:?}"
    echo '{"uploadUrl":"https://example.test/put","uploadHeaders":{}}'
    exit 0
  fi
  if [[ "$1" == "-X" && "${2:-}" == "PUT" ]]; then
    exit 0
  fi
  shift
done
exit 1
MOCK3
chmod +x "${mock_bin2}/curl"
export MOCK_UPLOAD_PAYLOAD="${upload_payload}"
"${ROOT_DIR}/scripts/upload-artifacts" \
  --spec "${TMPDIR}/spec.json" \
  --artifact "${TMPDIR}/fake.apk" \
  --target apk
jq -e '.target == "apk" and .fileName == "fake.apk" and (.sha256 | startswith("sha256:"))' "$upload_payload" >/dev/null

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

log "contract: Go encoding/json canonical vector"
escape_fixture="${ROOT_DIR}/scripts/tests/fixtures/canonical-escape-vector.json"
escape_hash="$(compute_spec_hash "$escape_fixture")"
if [[ "$escape_hash" != "sha256:eccff365dad1e93912b6af42098efb347d871fab5d1a25c467d4edb6829f801d" ]]; then
  log "canonical vector mismatch: $escape_hash"
  exit 1
fi

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
for name in ("reusable-prepare.yml", "reusable-sign-android.yml", "reusable-finalize-android.yml"):
    if name not in text:
        raise SystemExit(f"missing reusable workflow call: {name}")
if "upstream_result" not in text:
    raise SystemExit("finalize is not wired to upstream failure")
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
jq '.config.android.versionName = "1.2.3" | .config.android.versionCode = "7"' "$FIXTURE" > "$signed_spec"
signed_hash="$(compute_spec_hash "$signed_spec")"
jq --arg h "$signed_hash" '.specHash = $h' "$signed_spec" > "${TMPDIR}/signed-spec-hashed.json"
mock_sign_bin="${TMPDIR}/signbin"
mkdir -p "$mock_sign_bin"
cat > "${mock_sign_bin}/curl" <<'MOCKCURL'
#!/usr/bin/env bash
if [[ "$*" == *"android-signing"* ]]; then
  printf '%s\n' '{"keystoreBase64":"aGVsbG8=","keystorePassword":"ks-secret","keyPassword":"key-secret","keyAlias":"alias-secret","certificateSha256":"AA:BB"}'
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
  printf '%s\n' 'Signer #1 certificate SHA-256 digest: CC:DD'
  exit 0
fi
exit 0
MOCKA
cat > "${mock_sign_bin}/aapt" <<'MOCKP'
#!/usr/bin/env bash
printf "%s\n" "package: name='com.example.contract' versionCode='7' versionName='1.2.3'"
MOCKP
chmod +x "${mock_sign_bin}/curl" "${mock_sign_bin}/zipalign" "${mock_sign_bin}/apksigner" "${mock_sign_bin}/aapt"
if TMPDIR="$sign_tmp" PATH="${mock_sign_bin}:${PATH}" \
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
if find "$sign_tmp" -type f -print | grep -q .; then
  log "signing temp files were left behind"
  find "$sign_tmp" -type f -print >&2
  exit 1
fi

log "contract: sign-aab rejects fingerprint mismatch"
cat > "${mock_sign_bin}/jarsigner" <<'MOCKJ'
#!/usr/bin/env bash
exit 0
MOCKJ
cat > "${mock_sign_bin}/keytool" <<'MOCKK'
#!/usr/bin/env bash
printf '%s\n' '         SHA256: 11:22'
MOCKK
cat > "${mock_sign_bin}/bundletool" <<'MOCKB'
#!/usr/bin/env bash
printf '%s\n' '<manifest package="com.example.contract" android:versionCode="7" android:versionName="1.2.3">'
MOCKB
chmod +x "${mock_sign_bin}/jarsigner" "${mock_sign_bin}/keytool" "${mock_sign_bin}/bundletool"
printf 'dummy-aab' > "${TMPDIR}/unsigned.aab"
aab_spec="${TMPDIR}/aab-spec.json"
jq '.targets = ["aab"] | .config.android.versionName = "1.2.3" | .config.android.versionCode = "7"' "$FIXTURE" > "$aab_spec"
aab_hash="$(compute_spec_hash "$aab_spec")"
jq --arg h "$aab_hash" '.specHash = $h' "$aab_spec" > "${TMPDIR}/aab-spec-hashed.json"
if PATH="${mock_sign_bin}:${PATH}" \
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

log "contract: sensitive workflows are pinned to an immutable SHA"
python3 - "${ROOT_DIR}" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
text = (root / ".github/workflows/android-build.yml").read_text()
names = [
    "reusable-prepare.yml",
    "reusable-sign-android.yml",
    "reusable-finalize-android.yml",
]
for name in names:
    marker = f"prtmax/runall/.github/workflows/{name}@"
    if marker not in text:
        raise SystemExit(f"missing SHA pin for {name}")
    sha = text.split(marker, 1)[1].splitlines()[0].strip()
    if len(sha) != 40 or any(ch not in "0123456789abcdef" for ch in sha):
        raise SystemExit(f"pin for {name} is not a full SHA: {sha}")
    pinned = subprocess.check_output(["git", "-C", str(root), "show", f"{sha}:.github/workflows/{name}"])
    current = (root / ".github/workflows" / name).read_bytes()
    if pinned != current:
        raise SystemExit(f"pinned {name} does not match the file at HEAD")
PY

log "all contract tests passed"
