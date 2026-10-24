#!/usr/bin/env python3
"""Refuse an npm archive that breaks the package-root frozen-lock contract."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile


def verify_archive(archive, identity, lock):
    """Inspect without extraction; require canonical, unique, regular inputs."""
    seen = set()
    required = {}
    with tarfile.open(archive, "r:gz") as packed:
        for member in packed:
            parts = member.name.split("/")
            if (parts[0] != "package" or len(parts) < 2
                    or any(part in ("", ".", "..") for part in parts)
                    or "\\" in member.name):
                raise ValueError("unsafe archive member path")
            if member.name in seen:
                raise ValueError("duplicate archive member")
            seen.add(member.name)
            if not (member.isfile() or member.isdir()):
                raise ValueError("nonregular archive member")
            if member.name in ("package/bun.lock", "package/package.json"):
                if not member.isfile():
                    raise ValueError("nonregular required member")
                required[member.name] = packed.extractfile(member).read()
    if "package/bun.lock" not in required:
        raise ValueError("missing package/bun.lock")
    if required["package/bun.lock"] != lock:
        raise ValueError("packed bun.lock differs from committed source")
    if "package/package.json" not in required:
        raise ValueError("missing package/package.json")
    manifest = json.loads(required["package/package.json"])
    if not isinstance(manifest, dict) or any(
            manifest.get(key) != identity[key] for key in ("name", "version")):
        raise ValueError("packed package identity differs from source")
    return {"name": identity["name"], "version": identity["version"],
            "members": len(seen), "bunLockSHA256": hashlib.sha256(lock).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        lock = subprocess.check_output(
            ["git", "-C", str(args.source), "show", "HEAD:bun.lock"],
            stderr=subprocess.PIPE)
        if (args.source / "bun.lock").read_bytes() != lock:
            raise ValueError("source bun.lock differs from committed HEAD")
        identity = json.loads((args.source / "package.json").read_text())
        if any(not isinstance(identity.get(key), str) or not identity[key]
               for key in ("name", "version")):
            raise ValueError("invalid source package identity")
        result = verify_archive(args.archive, identity, lock)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"npm package contract REFUSED: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"status": "PASS", **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
