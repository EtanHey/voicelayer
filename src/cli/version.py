import json
from pathlib import Path
import re
import subprocess
import sys


root = Path(__file__).resolve().parents[2]
version = json.loads((root / "package.json").read_text())["version"]
commit = None
source = "package"
stamp = root / "build-info.json"
if stamp.exists():
    commit = json.loads(stamp.read_text())["gitCommit"]
elif (root / ".git").exists():
    source = "checkout"
    try:
        commit = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL, timeout=5).decode().strip()
    except (OSError, subprocess.SubprocessError):
        pass
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    commit = None
if "--json" in sys.argv[1:]:
    print(json.dumps({"version": version, "gitCommit": commit, "source": source}))
else:
    print(version)
