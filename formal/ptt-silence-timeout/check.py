"""Compatibility entry point for the shared pinned-TLC fail-closed runner."""
import subprocess
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
raise SystemExit(subprocess.call([sys.executable, str(root / "formal/check-model.py"), str(Path(__file__).resolve().parent), *sys.argv[1:]]))
