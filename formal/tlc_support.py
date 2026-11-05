"""Verify the vendored TLC artifact before caching or running it."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile


def tlc_jar():
    lock = json.loads(Path(__file__).with_name("tlc.lock.json").read_text())
    source = Path(__file__).parent / lock["path"]
    matches = lambda file: hashlib.sha256(file.read_bytes()).hexdigest() == lock["sha256"]
    assert matches(source), f"Vendored TLC checksum mismatch: {source}"
    directory = Path.home() / ".cache/tla" / lock["version"]
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "tla2tools.jar"
    if path.exists():
        assert matches(path), f"Cached TLC checksum mismatch: {path}"
    else:
        with tempfile.NamedTemporaryFile(dir=directory, suffix=".jar", delete=False) as temporary:
            pending = Path(temporary.name)
        try:
            shutil.copyfile(source, pending)
            assert matches(pending), "Copied TLC checksum mismatch"
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)
    return path


if __name__ == "__main__":
    print(tlc_jar())
