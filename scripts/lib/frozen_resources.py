"""Frozen native packaging resources for the Orion app assembler.

The authorized index maps each spec ref to a local path. Paths may be absolute
or relative to the index file, but the resolved file must stay inside the index
directory. URLs, parent segments, and symlinks are rejected.
"""

import base64
import hashlib
import json
from pathlib import Path


def fail(message):
    raise SystemExit(message)


def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail("resource index is not JSON")
        raise exc


def required_resources(spec):
    required = {}
    rows = spec.get("buildInput", {}).get("resources")
    if not isinstance(rows, list):
        fail("buildInput.resources is missing")
    for row in rows:
        ref, digest = row.get("ref"), row.get("digest")
        if not isinstance(ref, str) or not isinstance(digest, str):
            fail("buildInput.resources ref is invalid")
        if ref in required and required[ref] != digest:
            fail("frozen ref digest conflict")
        required[ref] = digest
    return required


def load_index(path):
    index_path = Path(path)
    if index_path.is_symlink():
        fail("resource symlink rejected")
    if not index_path.is_file():
        fail("frozen resource index is missing")
    mapping = load_json(index_path)
    if not isinstance(mapping, dict) or any(
        not isinstance(key, str) or not isinstance(value, str) for key, value in mapping.items()
    ):
        fail("resource index must map frozen refs to local paths")
    return index_path, mapping


def locate_resource(index_path, raw):
    if not isinstance(raw, str) or raw == "" or "://" in raw or "\\" in raw or "\x00" in raw:
        fail("resource index path rejected")
    requested = Path(raw)
    if any(part in {"", ".", ".."} for part in requested.parts):
        fail("resource index path rejected")
    current = Path(requested.anchor) if requested.is_absolute() else index_path.parent
    steps = requested.parts[1:] if requested.is_absolute() else requested.parts
    for step in steps:
        current = current / step
        if current.is_symlink():
            fail("resource symlink rejected")
    root = index_path.parent.resolve()
    resolved = current.resolve()
    if resolved != root and root not in resolved.parents:
        fail("resource file escapes the index directory")
    if not current.is_file():
        fail("frozen resource file missing")
    return current


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


MAX_PACKAGING_RESOURCES = 52
MAX_PACKAGING_BYTES = 36 * 1024 * 1024
PACKAGING_CONTENT_TYPES = {"image/png", "text/plain; charset=utf-8"}
PACKAGING_FIELDS = {"ref", "digest", "contentType", "contentBase64"}


def split_resources(spec):
    studio = {}
    legacy = {}
    for ref, digest in required_resources(spec).items():
        if ref.startswith("app-studio/"):
            studio[ref] = digest
        else:
            legacy[ref] = digest
    return studio, legacy


def spec_requests_studio(spec_path):
    studio, _legacy = split_resources(load_json(spec_path))
    return bool(studio)


def decode_packaging_resources(payload, studio):
    """Decode the prepare-only packaging response and recompute every digest.

    The payload is not a path list. Only refs already frozen in the spec are
    accepted, and the decoded bytes must hash to that spec digest.
    """
    if not isinstance(payload, list) or len(payload) != len(studio) or len(payload) > MAX_PACKAGING_RESOURCES:
        fail("packaging resources do not match the frozen spec")
    decoded = {}
    total = 0
    encoded_limit = (MAX_PACKAGING_BYTES // 3) * 4 + 4
    for item in payload:
        if not isinstance(item, dict) or set(item) - PACKAGING_FIELDS:
            fail("packaging resource is invalid")
        ref, digest = item.get("ref"), item.get("digest")
        content_type, encoded = item.get("contentType"), item.get("contentBase64")
        if not isinstance(ref, str) or studio.get(ref) != digest:
            fail("packaging resource ref is not in the frozen spec")
        if content_type not in PACKAGING_CONTENT_TYPES:
            fail("packaging resource content type rejected")
        if not isinstance(encoded, str) or encoded == "" or len(encoded) > encoded_limit:
            fail("packaging resource payload rejected")
        try:
            data = base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError):
            fail("packaging resource payload rejected")
        total += len(data)
        if len(data) == 0 or total > MAX_PACKAGING_BYTES:
            fail("packaging resource payload rejected")
        if digest_bytes(data) != digest:
            fail(f"packaging resource digest mismatch: {ref}")
        if ref in decoded:
            fail("packaging resource ref repeated")
        decoded[ref] = data
    if set(decoded) != set(studio):
        fail("packaging resources do not match the frozen spec")
    return decoded


def verified_legacy(index_path, legacy):
    index_path, mapping = load_index(index_path)
    if set(mapping) != set(legacy):
        fail("resource index refs do not match the frozen spec")
    files = {}
    for ref, digest in legacy.items():
        data = locate_resource(index_path, mapping[ref]).read_bytes()
        if digest_bytes(data) != digest:
            fail(f"frozen resource digest mismatch: {ref}")
        files[ref] = data
    return files


def write_resource_index(dest, files):
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    if any(dest.iterdir()):
        fail("packaging resource output is not empty")
    staged = {}
    for ref, data in files.items():
        name = staged_name(ref)
        target = dest / name
        if target.exists() or target.is_symlink():
            fail("packaging resource output path rejected")
        target.write_bytes(data)
        staged[ref] = name
    (dest / "index.json").write_text(json.dumps(staged, sort_keys=True) + "\n", encoding="utf-8")


def materialize_packaging_response(spec_path, response_path, dest, legacy_index=""):
    spec = load_json(spec_path)
    studio, legacy = split_resources(spec)
    if not studio:
        fail("spec has no App Studio resources")
    files = decode_packaging_resources(load_json(response_path), studio)
    if legacy:
        if not legacy_index:
            fail("authorized frozen resource index is missing")
        files.update(verified_legacy(legacy_index, legacy))
    write_resource_index(dest, files)


def staged_name(ref):
    return hashlib.sha256(ref.encode("utf-8")).hexdigest()


def iter_verified(spec, index_path):
    index_path, mapping = load_index(index_path)
    required = required_resources(spec)
    if set(mapping) != set(required):
        fail("resource index refs do not match the frozen spec")
    for ref, digest in required.items():
        file_path = locate_resource(index_path, mapping[ref])
        data = file_path.read_bytes()
        actual = digest_bytes(data)
        if actual != digest:
            fail(f"frozen resource digest mismatch: {ref}")
        yield ref, data


def materialize(spec_path, dest, root_arg="", index_arg=""):
    spec_path = Path(spec_path)
    dest = Path(dest)
    spec = load_json(spec_path)
    if index_arg:
        source_index = Path(index_arg)
    else:
        root = Path(root_arg) if root_arg else spec_path.parent / "frozen-resources"
        source_index = root / "index.json"
    staged = {}
    for ref, data in iter_verified(spec, source_index):
        name = staged_name(ref)
        target = dest / name
        target.write_bytes(data)
        staged[ref] = name
    (dest / "resources.json").write_text(
        json.dumps(staged, sort_keys=True) + "\n", encoding="utf-8"
    )


def stage(spec_path, index_path, dest):
    spec = load_json(spec_path)
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    if any(dest.iterdir()):
        fail("frozen resource output is not empty")
    staged = {}
    for ref, data in iter_verified(spec, index_path):
        name = staged_name(ref)
        (dest / name).write_bytes(data)
        staged[ref] = name
    (dest / "index.json").write_text(
        json.dumps(staged, sort_keys=True) + "\n", encoding="utf-8"
    )
