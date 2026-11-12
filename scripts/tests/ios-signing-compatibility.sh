#!/usr/bin/env bash
# Real PKCS#12 conversion; macOS keychain/codesign behavior is simulated on Linux.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/lib/common.sh"
source "$ROOT_DIR/scripts/lib/ios_signing.sh"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete; find "$work" -depth -type d -empty -delete' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Synthetic-Test -days 1 \
  -keyout "$work/original.key" -out "$work/original.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Test-CA -days 1 \
  -keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null
expected="$(openssl x509 -in "$work/original.pem" -fingerprint -sha256 -noout)"
for format in modern legacy modern-no-chain legacy-no-chain; do
  mkdir "$work/$format"
  set -- -export -in "$work/original.pem" -inkey "$work/original.key" \
    -passout pass:fixture-password -out "$work/$format/cert.p12"
  [[ "$format" != legacy* ]] || set -- "$@" -legacy
  [[ "$format" == *no-chain ]] || set -- "$@" -certfile "$work/ca.pem"
  openssl pkcs12 "$@"
  prepare_ios_pkcs12 "$work/$format" fixture-password
  openssl pkcs12 -in "$work/$format/import.p12" -passin pass:fixture-password \
    -info -nodes -out "$work/$format/roundtrip.pem" 2>"$work/$format/algorithms"
  grep -q 'pbeWithSHA1And3-KeyTripleDES-CBC' "$work/$format/algorithms"
  [[ "$(openssl x509 -in "$work/$format/roundtrip.pem" -fingerprint -sha256 -noout)" == "$expected" ]]
  openssl pkey -in "$work/original.key" -pubout > "$work/expected.pub"
  openssl pkey -in "$work/$format/roundtrip.pem" -pubout > "$work/actual.pub"
  cmp "$work/expected.pub" "$work/actual.pub"
  count=2
  [[ "$format" != *no-chain ]] || count=1
  [[ "$(grep -c 'BEGIN CERTIFICATE' "$work/$format/roundtrip.pem")" == "$count" ]]
done
if prepare_ios_pkcs12 "$work/modern" wrong-password >/dev/null 2>&1; then
  log 'wrong PKCS#12 password accepted'; exit 1
fi

expected_identity="$(openssl x509 -in "$work/original.pem" -fingerprint -sha1 -noout | sed 's/.*Fingerprint=//; s/://g')"
security() {
  printf '%s\n' "$*" >> "$work/security.calls"
  if [[ "$identity_mode" == policy && "$*" == *'-p codesigning'* ]] ||
     [[ "$identity_mode" == basic && "$*" != *'-p codesigning'* ]]; then
    printf '  1) %s "Synthetic-Test"\n' "$expected_identity"
  fi
}
for identity_mode in policy basic fingerprint; do
  [[ "$(find_ios_signing_identity temporary-keychain "$work/original.pem")" == "$expected_identity" ]]
done
grep -qx 'find-identity temporary-keychain' "$work/security.calls"

codesign() {
  printf '%s\n' "$*" >> "$work/codesign.calls"
  if [[ "$*" == *'--sign - '* ]]; then return 0; fi
  [[ "$sign_error" != none ]] || return 0
  printf '%s\n' "$sign_error" >&2
  return 1
}
for sign_error in 'no identity found' CSSMERR_TP_NOT_TRUSTED errSecInternalComponent; do
  sign_ios_target "$work" "$expected_identity" keychain Runner.app --entitlements entitlements.plist
done
[[ "$(grep -c -- '--sign - ' "$work/codesign.calls")" == 3 ]]
sign_error='unrelated signing failure'
if sign_ios_target "$work" "$expected_identity" keychain Runner.app 2>/dev/null; then
  log 'unrelated signing failure accepted'; exit 1
fi
[[ "$(grep -c -- '--sign - ' "$work/codesign.calls")" == 3 ]]
log 'iOS PKCS#12 compatibility, identity selection, and signing error contracts passed'
