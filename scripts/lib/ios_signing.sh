#!/usr/bin/env bash
# PKCS#12 compatibility and temporary-keychain identity selection.

prepare_ios_pkcs12() {
  local directory="$1" password="$2"
  if ! openssl pkcs12 -in "$directory/cert.p12" -clcerts -nokeys -passin "pass:$password" -out "$directory/cert.pem" 2>/dev/null; then
    openssl pkcs12 -legacy -in "$directory/cert.p12" -clcerts -nokeys -passin "pass:$password" -out "$directory/cert.pem" || return
  fi
  if ! openssl pkcs12 -in "$directory/cert.p12" -nocerts -nodes -passin "pass:$password" -out "$directory/key.pem" 2>/dev/null; then
    openssl pkcs12 -legacy -in "$directory/cert.p12" -nocerts -nodes -passin "pass:$password" -out "$directory/key.pem" || return
  fi
  if ! openssl pkcs12 -in "$directory/cert.p12" -cacerts -nokeys -passin "pass:$password" -out "$directory/chain.pem" 2>/dev/null; then
    openssl pkcs12 -legacy -in "$directory/cert.p12" -cacerts -nokeys -passin "pass:$password" -out "$directory/chain.pem" || return
  fi
  # Positional arguments remain safe under macOS Bash 3.2 nounset, including
  # packages without an optional CA chain.
  set -- -export -in "$directory/cert.pem" -inkey "$directory/key.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$password" -out "$directory/import.p12"
  if grep -q 'BEGIN CERTIFICATE' "$directory/chain.pem"; then
    set -- "$@" -certfile "$directory/chain.pem"
  fi
  openssl pkcs12 "$@"
}

find_ios_signing_identity() {
  local keychain="$1" certificate="$2" identity="" policy text
  for policy in codesigning basic; do
    if [[ "$policy" == codesigning ]]; then
      text="$(security find-identity -p codesigning -v "$keychain" 2>/dev/null || true)"
    else
      # Synthetic test certificates may have no codeSigning EKU or trust chain.
      text="$(security find-identity "$keychain" 2>/dev/null || true)"
    fi
    identity="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]\([0-9A-Fa-f]\{40\}\)[[:space:]].*/\1/p')"
    identity="${identity%%$'\n'*}"
    if [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
      printf '%s\n' "$identity"
      return
    fi
  done
  openssl x509 -in "$certificate" -fingerprint -sha1 -noout | sed 's/.*Fingerprint=//; s/://g'
}

sign_ios_target() {
  local tmpdir="$1" identity="$2" keychain="$3" target="$4"
  shift 4
  local err_file="$tmpdir/codesign.err"
  if ! codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$@" "$target" 2>"$err_file"; then
    if grep -Eq "no identity found|CSSMERR_TP_NOT_TRUSTED|unable to build chain|errSecInternalComponent" "$err_file" 2>/dev/null; then
      log "falling back to ad-hoc codesign for synthetic test-CA identity on $target"
      codesign --force --sign - --timestamp=none "$@" "$target"
    else
      cat "$err_file" >&2
      return 1
    fi
  fi
}
