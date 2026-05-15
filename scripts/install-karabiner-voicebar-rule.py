#!/usr/bin/env python3
"""Deprecated compatibility wrapper for the old VoiceBar Karabiner installer."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def main() -> int:
    script = Path(__file__).with_name("install-voicebar-f5-hidutil.sh")
    print(
        "VoiceBar F5 routing now uses macOS hidutil instead of Karabiner; "
        f"running {script.name}.",
        file=sys.stderr,
    )
    return subprocess.call([str(script), *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(main())
