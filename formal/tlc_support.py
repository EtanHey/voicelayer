"""Fetch only the checksum-pinned TLC artifact; never replace another lane's jar."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def tlc_jar():
    lock = json.loads(Path(__file__).with_name("tlc.lock.json").read_text())
    directory = Path.home() / ".cache/tla" / lock["version"]
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "tla2tools.jar"
    matches = lambda file: hashlib.sha256(file.read_bytes()).hexdigest() == lock["sha256"]
    if path.exists():
        assert matches(path), f"Cached TLC checksum mismatch: {path}"
    else:
        with tempfile.NamedTemporaryFile(dir=directory, suffix=".jar", delete=False) as temporary:
            pending = Path(temporary.name)
        try:
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
                            "--output", str(pending), lock["url"]], check=True, timeout=90)
            assert matches(pending), "Downloaded TLC checksum mismatch"
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)
    return path


if __name__ == "__main__":
    print(tlc_jar())
