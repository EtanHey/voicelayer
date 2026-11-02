#!/bin/bash
# Git tree entries hash tracked content, modes and names, never checkout mtimes/pyc.
set -euo pipefail
git ls-tree -r "$1" -- ratchet/run.py ratchet/lock-client.ts ratchet/fixture-rec.py ratchet/fixture-tts.py | shasum -a 256 | cut -d ' ' -f 1
