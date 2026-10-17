#!/usr/bin/env python3
"""Canonical Release Build Spec digest matching Mercury encoding/json.

The hashed object is the v1 CreateBuildSpec payload: schemaVersion, integer
identity, fixed FrozenConfig field order, sorted and deduplicated targets,
and releaseSnapshotDigest. The releaseSnapshot object itself is not hashed.
Free-form maps (the bundled runtime Release) have sorted keys. Struct fields
keep Go's declaration order. encoding/json escapes &, <, >, U+2028, and U+2029.
"""

import hashlib
import json
import sys

SCHEMA_VERSION = "cosmos.release-build.v1"
RELEASE_ID_FIELDS = ("releaseId", "releaseRevisionId", "tenantId", "appId")


class CanonicalError(SystemExit):
    pass


def fail(message):
    raise CanonicalError(message)


def go_dumps(value):
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return (
        raw.replace("&", r"\u0026")
        .replace("<", r"\u003c")
        .replace(">", r"\u003e")
        .replace("\u2028", r"\u2028")
        .replace("\u2029", r"\u2029")
    )


def as_object(value, name):
    if not isinstance(value, dict):
        fail(f"{name} must be an object")
    return value


def as_list(value, name):
    if not isinstance(value, list):
        fail(f"{name} must be an array")
    return value


def as_text(value, name):
    if not isinstance(value, str) or value == "":
        fail(f"{name} must be a non-empty string")
    return value


def as_int(value, name):
    if isinstance(value, bool) or isinstance(value, float) or not isinstance(value, int):
        fail(f"{name} must be an integer")
    return value


def as_id_value(value, name):
    if isinstance(value, str):
        if not value.isdigit() or (len(value) > 1 and value.startswith("0")):
            fail(f"{name} must be a canonical integer")
        value = int(value)
    return as_int(value, name)


def as_id(value, name):
    number = as_id_value(value, name)
    if number <= 0 or number > 9223372036854775807:
        fail(f"{name} must be a positive int64")
    return number


def as_id_string(value, name):
    return str(as_id(value, name))


def as_digest(value, name):
    text = as_text(value, name)
    if len(text) != 71 or not text.startswith("sha256:"):
        fail(f"{name} must be a SHA-256 digest")
    hex_part = text[7:]
    if any(ch not in "0123456789abcdef" for ch in hex_part):
        fail(f"{name} must be a SHA-256 digest")
    return text


def as_commit(value, name):
    text = as_text(value, name)
    if len(text) != 40 or any(ch not in "0123456789abcdef" for ch in text) or set(text) == {"0"}:
        fail(f"{name} must be an exact Git commit")
    return text


def sorted_json(value, name):
    if isinstance(value, dict):
        keys = list(value)
        if any(not isinstance(key, str) for key in keys):
            fail(f"{name} keys must be strings")
        return {key: sorted_json(value[key], f"{name}.{key}") for key in sorted(keys)}
    if isinstance(value, list):
        return [sorted_json(item, f"{name}[]") for item in value]
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        if not value.is_integer():
            fail(f"{name} must not contain floating values")
        number = int(value)
        if number > 9007199254740991 or number < -9007199254740991:
            fail(f"{name} integer is not an exact JSON number")
        return number
    fail(f"{name} contains an unsupported JSON value")


def struct_list(items, fields, name, sort_key):
    rows = []
    for index, item in enumerate(as_list(items, name)):
        source = as_object(item, f"{name}[{index}]")
        row = {field: source.get(field) for field in fields}
        rows.append(row)
    rows.sort(key=sort_key)
    return rows


def canonical_config(config):
    config = as_object(config, "config")
    orion = as_object(config.get("orion"), "config.orion")
    app = as_object(config.get("app"), "config.app")
    release = as_object(config.get("release"), "config.release")
    environment = as_object(config.get("environment"), "config.environment")
    trust = as_object(config.get("trust"), "config.trust")
    signing = as_object(config.get("signing"), "config.signing")

    brand_assets = struct_list(
        config.get("brandAssets"),
        ("kind", "ref", "digest"),
        "config.brandAssets",
        lambda row: f"{as_text(row['kind'], 'brandAssets.kind')}\0{as_text(row['ref'], 'brandAssets.ref')}",
    )
    for row in brand_assets:
        row["digest"] = as_digest(row["digest"], "brandAssets.digest")

    endpoints = struct_list(
        environment.get("endpoints"),
        ("name", "url", "version", "digest"),
        "config.environment.endpoints",
        lambda row: f"{as_text(row['name'], 'endpoints.name')}\0{as_text(row['url'], 'endpoints.url')}",
    )
    for row in endpoints:
        row["version"] = as_text(row["version"], "endpoints.version")
        row["digest"] = as_digest(row["digest"], "endpoints.digest")

    languages = struct_list(
        config.get("languages"),
        ("locale", "ref", "digest"),
        "config.languages",
        lambda row: f"{as_text(row['locale'], 'languages.locale')}\0{as_text(row['ref'], 'languages.ref')}",
    )
    for row in languages:
        row["digest"] = as_digest(row["digest"], "languages.digest")

    ready = signing.get("ready")
    if not isinstance(ready, bool):
        fail("config.signing.ready must be a boolean")

    return {
        "orion": {
            "commit": as_commit(orion.get("commit"), "config.orion.commit"),
            "toolchainVersion": as_text(orion.get("toolchainVersion"), "config.orion.toolchainVersion"),
        },
        "app": {
            "applicationId": app.get("applicationId")
            if isinstance(app.get("applicationId"), str)
            else fail("config.app.applicationId must be a string"),
            "bundleId": app.get("bundleId")
            if isinstance(app.get("bundleId"), str)
            else fail("config.app.bundleId must be a string"),
            "displayName": as_text(app.get("displayName"), "config.app.displayName"),
            "versionName": as_text(app.get("versionName"), "config.app.versionName"),
            "versionCode": as_id(as_int(app.get("versionCode"), "config.app.versionCode"), "config.app.versionCode"),
        },
        "release": {
            "releaseId": as_id_string(release.get("releaseId"), "config.release.releaseId"),
            "releaseRevisionId": as_id_string(release.get("releaseRevisionId"), "config.release.releaseRevisionId"),
            "tenantId": as_id_string(release.get("tenantId"), "config.release.tenantId"),
            "appId": as_id_string(release.get("appId"), "config.release.appId"),
            "channel": as_text(release.get("channel"), "config.release.channel"),
            "version": as_text(release.get("version"), "config.release.version"),
            "runtimeReleaseId": as_text(release.get("runtimeReleaseId"), "config.release.runtimeReleaseId"),
            "snapshotDigest": as_digest(release.get("snapshotDigest"), "config.release.snapshotDigest"),
            "bundled": sorted_json(release.get("bundled"), "config.release.bundled"),
            "bundledDigest": as_digest(release.get("bundledDigest"), "config.release.bundledDigest"),
        },
        "brandAssets": brand_assets,
        "environment": {
            "name": as_text(environment.get("name"), "config.environment.name"),
            "releaseChannel": as_text(environment.get("releaseChannel"), "config.environment.releaseChannel"),
            "mercuryBaseUrl": as_text(environment.get("mercuryBaseUrl"), "config.environment.mercuryBaseUrl"),
            "runtimeBaseUrl": as_text(environment.get("runtimeBaseUrl"), "config.environment.runtimeBaseUrl"),
            "endpoints": endpoints,
        },
        "languages": languages,
        "trust": {
            "domain": as_text(trust.get("domain"), "config.trust.domain"),
            "rootKeyId": as_text(trust.get("rootKeyId"), "config.trust.rootKeyId"),
            "rootKeyVersion": as_id(as_int(trust.get("rootKeyVersion"), "config.trust.rootKeyVersion"), "config.trust.rootKeyVersion"),
            "algorithm": as_text(trust.get("algorithm"), "config.trust.algorithm"),
            "publicKey": as_text(trust.get("publicKey"), "config.trust.publicKey"),
            "digest": as_digest(trust.get("digest"), "config.trust.digest"),
        },
        "signing": {
            "profileRef": as_text(signing.get("profileRef"), "config.signing.profileRef"),
            "ready": ready,
        },
    }


def canonical_targets(platform, targets):
    allowed = {"android": {"aab", "apk"}, "ios": {"ipa"}}.get(platform)
    if allowed is None:
        fail("platform must be android or ios")
    values = as_list(targets, "targets")
    if not values or any(not isinstance(item, str) for item in values):
        fail("targets must be supported for the platform")
    if any(item not in allowed for item in values):
        fail("targets must be supported for the platform")
    return sorted(set(values))


def canonical_payload(doc):
    doc = as_object(doc, "build spec")
    platform = as_text(doc.get("platform"), "platform")
    repository = doc.get("repository")
    if not isinstance(repository, str) or not repository.strip():
        fail("repository must be a non-empty string")
    payload = {
        "schemaVersion": as_text(doc.get("schemaVersion"), "schemaVersion"),
        "releaseId": as_id(doc.get("releaseId"), "releaseId"),
        "releaseRevisionId": as_id(doc.get("releaseRevisionId"), "releaseRevisionId"),
        "tenantId": as_id(doc.get("tenantId"), "tenantId"),
        "appId": as_id(doc.get("appId"), "appId"),
        "repository": repository.strip(),
        "sourceCommit": as_commit(doc.get("sourceCommit"), "sourceCommit"),
        "platform": platform,
        "targets": canonical_targets(platform, doc.get("targets")),
        "config": canonical_config(doc.get("config")),
        "releaseSnapshotDigest": as_digest(doc.get("releaseSnapshotDigest"), "releaseSnapshotDigest"),
        "artifactPrefix": doc.get("artifactPrefix").strip()
        if isinstance(doc.get("artifactPrefix"), str)
        else fail("artifactPrefix must be a string"),
    }
    if payload["schemaVersion"] != SCHEMA_VERSION:
        fail("unsupported schemaVersion")
    prefix = payload["artifactPrefix"]
    if prefix.startswith("/") or ".." in prefix:
        fail("artifactPrefix is invalid")
    return payload


def canonical_bytes(doc):
    return go_dumps(canonical_payload(doc)).encode("utf-8")


def main():
    if len(sys.argv) != 2:
        fail("usage: spec_hash.py <spec.json>")
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
    digest = hashlib.sha256(canonical_bytes(document)).hexdigest()
    sys.stdout.write(f"sha256:{digest}\n")


if __name__ == "__main__":
    try:
        main()
    except CanonicalError as exc:
        raise SystemExit(str(exc)) from None
