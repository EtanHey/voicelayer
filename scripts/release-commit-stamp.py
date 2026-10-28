import argparse
import json
import os
from pathlib import Path
import re
import sys
import tarfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("stamp", "verify"))
    parser.add_argument("--source", type=Path, default=Path.cwd())
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    try:
        commit = os.environ.get("GITHUB_SHA", "")
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("GITHUB_SHA must be the full release commit")
        expected = {"gitCommit": commit}
        if args.operation == "stamp":
            stamp = args.source / "build-info.json"
            if stamp.exists() and json.loads(stamp.read_text()) != expected:
                raise ValueError("refusing to relabel an existing stamp")
            stamp.write_text(json.dumps(expected) + "\n")
        else:
            if args.archive is None:
                raise ValueError("verify requires --archive")
            with tarfile.open(args.archive, "r:gz") as archive:
                members = [m for m in archive if m.name == "package/build-info.json"]
                if len(members) != 1 or not members[0].isfile():
                    raise ValueError("archive must contain one regular build-info.json")
                if json.load(archive.extractfile(members[0])) != expected:
                    raise ValueError("packed stamp differs from GITHUB_SHA")
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"release commit stamp REFUSED: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"status": "PASS", "gitCommit": commit}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
