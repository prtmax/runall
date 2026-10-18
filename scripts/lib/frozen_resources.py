"""Frozen brand and language files for the Orion release generator.

The authorized index maps each spec ref to a local path. Paths may be absolute
or relative to the index file, but the resolved file must stay inside the index
directory. URLs, parent segments, and symlinks are rejected.
"""

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
    config = spec["config"]
    required = {}
    for field in ("brandAssets", "languages"):
        rows = config.get(field)
        if not isinstance(rows, list) or not rows:
            fail(f"config.{field} is missing")
        for row in rows:
            ref, digest = row.get("ref"), row.get("digest")
            if not isinstance(ref, str) or not isinstance(digest, str):
                fail(f"config.{field} ref is invalid")
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
    return "sha256:" + hashlib.sha256(data).hexdigest()


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
