import json
from pathlib import Path
import re
import subprocess
import sys


root = Path(__file__).resolve().parents[2]
version = json.loads((root / "package.json").read_text())["version"]
commit = None
source = None
stamp = root / "build-info.json"
if (root / ".git").exists():
    source = "checkout"
    try:
        commit = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL, timeout=5).decode().strip()
    except (OSError, subprocess.SubprocessError):
        pass
elif stamp.exists():
    try:
        commit = json.loads(stamp.read_text())["gitCommit"]
        source = "package"
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    commit = None
    source = None
if "--json" in sys.argv[1:]:
    print(json.dumps({"version": version, "gitCommit": commit, "source": source}))
else:
    print(version)
