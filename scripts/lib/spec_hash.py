#!/usr/bin/env python3
"""Canonical build-spec digest matching Mercury encoding/json payload hashing.

The hashed object is the Go CreateBuildSpec payload, not the whole API
document. Map keys are sorted. Struct field order is fixed. HTML-sensitive
characters are escaped the way encoding/json does (& < >).
"""

import hashlib
import json
import sys


def sort_value(value):
    if isinstance(value, dict):
        return {key: sort_value(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [sort_value(item) for item in value]
    return value


def as_int(doc, key):
    if key not in doc or doc[key] is None or doc[key] == "":
        raise SystemExit(f"canonical spec missing {key}")
    return int(doc[key])


def go_dumps(value):
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return raw.replace("&", r"\u0026").replace("<", r"\u003c").replace(">", r"\u003e")


def canonical_bytes(doc):
    if not isinstance(doc, dict):
        raise SystemExit("build spec must be a JSON object")
    targets = doc.get("targets")
    if not isinstance(targets, list):
        raise SystemExit("canonical spec missing targets")
    payload = {
        "releaseId": as_int(doc, "releaseId"),
        "releaseRevisionId": as_int(doc, "releaseRevisionId"),
        "tenantId": as_int(doc, "tenantId"),
        "appId": as_int(doc, "appId"),
        "repository": doc["repository"],
        "sourceCommit": doc["sourceCommit"],
        "platform": doc["platform"],
        "targets": targets,
        "config": sort_value(doc.get("config") or {}),
        "releaseSnapshot": sort_value(doc.get("releaseSnapshot") or {}),
        "artifactPrefix": doc.get("artifactPrefix") or "",
    }
    return go_dumps(payload).encode("utf-8")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: spec_hash.py <spec.json>")
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
    digest = hashlib.sha256(canonical_bytes(document)).hexdigest()
    sys.stdout.write(f"sha256:{digest}\n")


if __name__ == "__main__":
    main()
