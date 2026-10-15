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

log "all contract tests passed"
