#!/usr/bin/env bash
# Both release and QA bundles must contain no Python bytecode artifacts.
set -euo pipefail
if [[ $# -ne 1 || ! -d "$1/Contents" ]]; then
  echo "usage: $0 <built app bundle>" >&2
  exit 2
fi
artifacts=$(find -H "$1" \( -name __pycache__ -o -name '*.pyc' \) -print)
if [[ -n "$artifacts" ]]; then
  printf 'error: Python cache artifacts in bundle:\n%s\n' "$artifacts" >&2
  exit 1
fi
printf '[check-voicebar-python-cache-free] no Python cache artifacts\n'
