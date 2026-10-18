#!/usr/bin/env bash
# Load Android signing material and verify the bound alias before signing.
# Passwords are written to mode 0600 files and are not passed on command lines.

fetch_android_material() {
  local url="$1" dest="$2"
  require_cmd curl
  curl --fail-with-body -sS \
    -H "Authorization: Bearer ${COSMOS_BUILD_CREDENTIAL}" \
    "${url%/}/build-runs/${BUILD_RUN_ID}/android-signing?target=${SIGN_TARGET}" \
    > "$dest"
}

prepare_android_signing() {
  local spec="$1" target="$2" tmpdir="$3"
  local policy_dir
  policy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SIGN_TARGET="$target"
  require_cmd python3
  require_cmd jq
  keystore="${tmpdir}/keystore.jks"
  if [[ -n "${ANDROID_KEYSTORE_PATH:-}" ]]; then
    cp "${ANDROID_KEYSTORE_PATH}" "$keystore"
    chmod 600 "$keystore"
    umask 077
    printf '%s' "${ANDROID_KEYSTORE_PASSWORD:-}" > "${tmpdir}/store.pass"
    printf '%s' "${ANDROID_KEY_PASSWORD:-${ANDROID_KEYSTORE_PASSWORD:-}}" > "${tmpdir}/key.pass"
    alias_name="${ANDROID_KEY_ALIAS:-}"
    python3 - "$spec" "$target" "$alias_name" "$tmpdir/identity.json" <<'PY'
import json, re, sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
target, alias, dest = sys.argv[2], sys.argv[3], sys.argv[4]
targets = spec.get("targets") or []
if target not in targets or len(targets) != 1:
    raise SystemExit("signing purpose does not match the artifact")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", alias or ""):
    raise SystemExit("keystore alias is invalid")
purpose = "direct" if target == "apk" else "play_upload"
json.dump({"alias": alias, "certificateSha256": "", "purpose": purpose, "target": target}, open(dest, "w", encoding="utf-8"))
PY
  else
    assert_non_empty "COSMOS_BUILD_SIGN_MATERIAL_URL" "${COSMOS_BUILD_SIGN_MATERIAL_URL:-}"
    assert_non_empty "COSMOS_BUILD_CREDENTIAL" "${COSMOS_BUILD_CREDENTIAL:-}"
    assert_non_empty "BUILD_RUN_ID" "${BUILD_RUN_ID:-}"
    fetch_android_material "${COSMOS_BUILD_SIGN_MATERIAL_URL}" "${tmpdir}/material.json"
    python3 "${policy_dir}/signing_policy.py" extract-android \
      --spec "$spec" --material "${tmpdir}/material.json" --target "$target" --output-dir "$tmpdir"
    rm -f "${tmpdir}/material.json"
    alias_name="$(jq -r '.alias' "${tmpdir}/identity.json")"
    if [[ -z "$EXPECTED_FINGERPRINT" ]]; then
      EXPECTED_FINGERPRINT="$(jq -r '.certificateSha256' "${tmpdir}/identity.json")"
    else
      local want got
      want="$(normalize_sha256 "$EXPECTED_FINGERPRINT")"
      got="$(jq -r '.certificateSha256' "${tmpdir}/identity.json")"
      if [[ "$want" != "$got" ]]; then
        log "certificate fingerprint does not match the frozen material"
        exit 1
      fi
      EXPECTED_FINGERPRINT="$want"
    fi
  fi
  [[ -s "${tmpdir}/store.pass" && -s "${tmpdir}/key.pass" ]] || {
    log "android signing material incomplete"
    exit 1
  }
  assert_non_empty "keystore alias" "$alias_name"
  confirm_android_keystore_identity
}

confirm_android_keystore_identity() {
  local listed fp
  require_cmd keytool
  if ! listed="$(keytool -list -v -keystore "$keystore" -storepass:file "${tmpdir}/store.pass" -alias "$alias_name" 2>"${tmpdir}/keytool.err")"; then
    log "android keystore could not be unlocked for the bound alias"
    exit 1
  fi
  rm -f "${tmpdir}/keytool.err"
  fp="$(printf '%s\n' "$listed" | sed -n 's/^[[:space:]]*SHA256: //p' | head -1 | tr -d '[:space:]')"
  fp="$(normalize_sha256 "$fp")"
  if [[ -z "$EXPECTED_FINGERPRINT" ]]; then
    EXPECTED_FINGERPRINT="$fp"
  elif [[ "$fp" != "$(normalize_sha256 "$EXPECTED_FINGERPRINT")" ]]; then
    log "keystore certificate does not match the bound fingerprint"
    exit 1
  else
    EXPECTED_FINGERPRINT="$fp"
  fi
}
