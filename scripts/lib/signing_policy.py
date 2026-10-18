#!/usr/bin/env python3
"""Validate frozen signing identity before any signature is produced.

The v1 Spec hash stays unchanged. Secrets stay in the material payload and are
written only to caller-supplied files. This module never prints those values.
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import plistlib
import re
import sys
from pathlib import Path

FORBIDDEN_SPEC_KEYS = {
    "password",
    "token",
    "secret",
    "privatekey",
    "private_key",
    "entitlements",
    "keystore",
    "provisioningprofile",
    "certificate",
}
ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DIST_METHODS = {
    "app_store": "app-store",
    "ad_hoc": "ad-hoc",
    "enterprise": "enterprise",
}


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_json(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        fail("signing input is not readable json")
    if not isinstance(value, dict):
        fail("signing input must be an object")
    return value


def reject_spec_injection(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or key.lower() in FORBIDDEN_SPEC_KEYS:
                fail("build spec contains a forbidden signing field")
            reject_spec_injection(item)
    elif isinstance(value, list):
        for item in value:
            reject_spec_injection(item)


def normalize_sha256(value, label):
    if not isinstance(value, str):
        fail(f"{label} is not a SHA-256 digest")
    raw = value.strip().lower()
    if raw.startswith("sha256:"):
        raw = raw[7:]
    raw = raw.replace(":", "").replace(" ", "")
    if not SHA256_RE.fullmatch(raw):
        fail(f"{label} is not a SHA-256 digest")
    return raw


def profile_ref(spec):
    signing = spec.get("config", {}).get("signing", {})
    if not isinstance(signing, dict):
        fail("frozen signing profile is missing")
    ref = signing.get("profileRef")
    if not isinstance(ref, str) or not ref.strip() or signing.get("ready") is not True:
        fail("frozen signing profile is not ready")
    return ref


def bound_ref(material, spec):
    ref = material.get("signingMaterialRef")
    if not isinstance(ref, str) or ref != profile_ref(spec):
        fail("signing material ref does not match the frozen spec")
    return ref


def continuity(material, current):
    previous = material.get("previousCertificateSha256", "")
    if previous in ("", None):
        return
    previous = normalize_sha256(previous, "previous certificate")
    if previous == current:
        return
    if material.get("signatureChangeAuthorized") is not True:
        fail("signature continuity refused")


def purpose_for(spec, material, target):
    targets = spec.get("targets")
    if not isinstance(targets, list) or not targets:
        fail("build targets are invalid")
    raw = material.get("purpose", "")
    if raw in ("", None):
        if len(targets) != 1:
            fail("signing purpose is required when the spec signs multiple artifacts")
        raw = "direct" if target == "apk" else "play_upload"
    if raw not in {"direct", "play_upload"}:
        fail("signing purpose is invalid")
    expected = "direct" if target == "apk" else "play_upload"
    if raw != expected or target not in targets:
        fail("signing purpose does not match the artifact")
    return raw


def secret_text(material, key):
    value = material.get(key)
    if not isinstance(value, str) or value.strip() == "" or value == "null":
        fail("signing material incomplete")
    return value


def write_secret(path, value):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(value)


def decode_b64(value, label):
    if not isinstance(value, str) or value.strip() == "":
        fail(f"{label} is missing")
    try:
        return base64.b64decode(value, validate=True)
    except Exception:
        fail(f"{label} is invalid")


def write_public(path, payload):
    Path(path).write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")


def extract_android(spec_path, material_path, target, output_dir):
    spec = load_json(spec_path)
    material = load_json(material_path)
    reject_spec_injection(spec)
    if spec.get("platform") != "android":
        fail("android signing requires an android spec")
    ref = bound_ref(material, spec)
    cert = normalize_sha256(material.get("certificateSha256"), "certificate")
    continuity(material, cert)
    purpose = purpose_for(spec, material, target)
    alias = material.get("keyAlias")
    if not isinstance(alias, str) or not ALIAS_RE.fullmatch(alias):
        fail("keystore alias is invalid")
    store = secret_text(material, "keystorePassword")
    key = material.get("keyPassword", store)
    key = secret_text({"keyPassword": key}, "keyPassword")
    keystore = decode_b64(material.get("keystoreBase64"), "keystore")
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    (output / "keystore.jks").write_bytes(keystore)
    os.chmod(output / "keystore.jks", 0o600)
    write_secret(output / "store.pass", store)
    write_secret(output / "key.pass", key)
    write_public(
        output / "identity.json",
        {
            "alias": alias,
            "certificateSha256": cert,
            "purpose": purpose,
            "signingMaterialRef": ref,
            "target": target,
        },
    )


def load_plist(path):
    try:
        value = plistlib.loads(Path(path).read_bytes())
    except Exception:
        fail("profile plist is invalid")
    if not isinstance(value, dict):
        fail("profile plist is invalid")
    return value


def distribution_matches(profile, distribution):
    if distribution not in DIST_METHODS:
        fail("ios distribution is not a release method")
    entitlements = profile.get("Entitlements") or {}
    if isinstance(entitlements, dict) and entitlements.get("get-task-allow") is True:
        fail("development profile cannot sign a release IPA")
    devices = profile.get("ProvisionedDevices")
    all_devices = profile.get("ProvisionsAllDevices") is True
    if distribution == "app_store" and (all_devices or isinstance(devices, list)):
        fail("profile distribution does not match app_store")
    if distribution == "ad_hoc" and (all_devices or not isinstance(devices, list) or not devices):
        fail("profile distribution does not match ad_hoc")
    if distribution == "enterprise" and not all_devices:
        fail("profile distribution does not match enterprise")
    name = profile.get("Name") or ""
    if not isinstance(name, str) or "debug" in name.lower():
        fail("debug profile cannot sign a release IPA")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        fail("profile expiration missing")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.timezone.utc)
    if expires <= datetime.datetime.now(datetime.timezone.utc):
        fail("profile expired")


def certificate_in_profile(profile, cert):
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        fail("profile certificate is missing")
    found = False
    for item in certificates:
        if isinstance(item, bytes) and hashlib.sha256(item).hexdigest() == cert:
            found = True
    if not found:
        fail("profile certificate does not match the bound certificate")


def authorized_entitlements(profile, app, team, bundle):
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict) or not entitlements:
        fail("profile entitlements missing")
    teams = profile.get("TeamIdentifier") or []
    if team not in teams:
        fail("profile team mismatch")
    app_id = f"{team}.{bundle}"
    if entitlements.get("application-identifier") != app_id:
        fail("profile bundle id mismatch")
    requested = None
    for name in ("archived-expanded-entitlements.plist", "Entitlements.plist"):
        candidate = Path(app) / name
        if candidate.is_file() and not candidate.is_symlink():
            requested = load_plist(candidate)
            break
    if requested is None:
        requested = {"application-identifier": app_id}
    if not isinstance(requested, dict):
        fail("app entitlements are invalid")
    if "application-identifier" in requested and requested["application-identifier"] != app_id:
        fail("app identifier entitlement mismatch")
    requested["application-identifier"] = app_id
    signed = {}
    for key, value in requested.items():
        if key not in entitlements or entitlements[key] != value:
            fail("app entitlement is not authorized by the profile")
        signed[key] = value
    return signed


def check_export_options(material, distribution, bundle_ids):
    raw = material.get("exportOptionsPlistBase64", "")
    if raw in ("", None):
        return
    try:
        options = plistlib.loads(decode_b64(raw, "export options"))
    except SystemExit:
        raise
    except Exception:
        fail("export options plist is invalid")
    if not isinstance(options, dict):
        fail("export options plist is invalid")
    if "entitlements" in {str(key).lower() for key in options}:
        fail("export options cannot inject entitlements")
    method = options.get("method")
    if method != DIST_METHODS[distribution]:
        fail("export options distribution does not match the bound profile")
    profiles = options.get("provisioningProfiles") or {}
    if profiles and (not isinstance(profiles, dict) or set(profiles) - bundle_ids):
        fail("export options name a bundle that is not in this app")


def prepare_profile(raw, team, bundle, distribution, cert, app):
    try:
        profile = plistlib.loads(raw)
    except Exception:
        fail("provisioning profile is invalid")
    if not isinstance(profile, dict):
        fail("provisioning profile is invalid")
    distribution_matches(profile, distribution)
    certificate_in_profile(profile, cert)
    return authorized_entitlements(profile, app, team, bundle)


def extract_ios(spec_path, material_path, app, output_dir):
    spec = load_json(spec_path)
    material = load_json(material_path)
    reject_spec_injection(spec)
    if spec.get("platform") != "ios":
        fail("ios signing requires an ios spec")
    bundle = spec.get("config", {}).get("app", {}).get("bundleId")
    if not isinstance(bundle, str) or not bundle:
        fail("bundle id is missing")
    ref = bound_ref(material, spec)
    cert = normalize_sha256(material.get("certificateSha256"), "certificate")
    continuity(material, cert)
    team = material.get("teamId")
    distribution = material.get("distribution")
    if not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        fail("ios signing material incomplete")
    if not isinstance(distribution, str):
        fail("ios signing material incomplete")
    password = secret_text(material, "certificatePassword")
    certificate = decode_b64(material.get("certificateP12Base64"), "certificate")
    profile_bytes = decode_b64(material.get("provisioningProfileBase64"), "provisioning profile")
    app_path = Path(app)
    signed = prepare_profile(profile_bytes, team, bundle, distribution, cert, app_path)
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    (output / "cert.p12").write_bytes(certificate)
    os.chmod(output / "cert.p12", 0o600)
    (output / "profile.mobileprovision").write_bytes(profile_bytes)
    write_secret(output / "cert.pass", password)
    (output / "entitlements.plist").write_bytes(plistlib.dumps(signed))

    extensions = []
    appexes = sorted(
        path for path in app_path.glob("PlugIns/*.appex") if path.is_dir() and not path.is_symlink()
    )
    supplied = material.get("extensions", [])
    if supplied in ("", None):
        supplied = []
    if not isinstance(supplied, list):
        fail("extension signing material is invalid")
    if bool(appexes) != bool(supplied):
        fail("extension signing material does not match the app")
    by_bundle = {}
    for item in supplied:
        if not isinstance(item, dict):
            fail("extension signing material is invalid")
        ext_bundle = item.get("bundleId")
        if not isinstance(ext_bundle, str) or not ext_bundle.startswith(bundle + "."):
            fail("extension bundle id is not nested under the app")
        if ext_bundle in by_bundle:
            fail("extension bundle id is duplicated")
        by_bundle[ext_bundle] = item
    for appex in appexes:
        info_path = appex / "Info.plist"
        if not info_path.is_file() or info_path.is_symlink():
            fail("extension Info.plist is missing")
        info = load_plist(info_path)
        ext_bundle = info.get("CFBundleIdentifier")
        item = by_bundle.get(ext_bundle)
        if item is None:
            fail("extension signing material is missing")
        ext_profile = decode_b64(item.get("provisioningProfileBase64"), "extension profile")
        ext_signed = prepare_profile(ext_profile, team, ext_bundle, distribution, cert, appex)
        safe = hashlib.sha256(ext_bundle.encode()).hexdigest()
        profile_path = output / f"ext-{safe}.mobileprovision"
        ent_path = output / f"ext-{safe}.entitlements"
        profile_path.write_bytes(ext_profile)
        ent_path.write_bytes(plistlib.dumps(ext_signed))
        extensions.append(
            {
                "bundleId": ext_bundle,
                "relative": str(appex.relative_to(app_path)),
                "profile": str(profile_path),
                "entitlements": str(ent_path),
            }
        )
    if len(by_bundle) != len(appexes):
        fail("extension signing material does not match the app")
    check_export_options(material, distribution, {bundle, *(item["bundleId"] for item in extensions)})
    write_public(output / "extensions.json", extensions)
    write_public(
        output / "identity.json",
        {
            "bundleId": bundle,
            "certificateSha256": cert,
            "distribution": distribution,
            "signingMaterialRef": ref,
            "teamId": team,
        },
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("extract-android", "extract-ios"))
    parser.add_argument("--spec", required=True)
    parser.add_argument("--material", required=True)
    parser.add_argument("--target")
    parser.add_argument("--app")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    if args.command == "extract-android":
        if args.target not in {"apk", "aab"}:
            fail("android signing target is invalid")
        extract_android(args.spec, args.material, args.target, args.output_dir)
        return
    if not args.app:
        fail("ios app path is missing")
    extract_ios(args.spec, args.material, args.app, args.output_dir)


if __name__ == "__main__":
    main()
