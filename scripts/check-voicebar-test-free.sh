#!/usr/bin/env bash
# Reject our test sources/fixtures in the copied app source, before signing it.
# Vendored node_modules are outside this first-party source privacy check.
# Exit 0 clean, 1 tests found, 2 invalid bundle or failed inspection.
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1/Contents/Resources/src" ]]; then
    printf 'usage: %s <VoiceBar.app with Contents/Resources/src>\n' "$0" >&2
    exit 2
fi

source_root="$1/Contents/Resources/src"
if ! found=$(find "$source_root" \( -name '__tests__' -o -name '*.test.ts' \) -print); then
    printf 'error: could not inspect bundled source %s\n' "$source_root" >&2
    exit 2
fi
if [[ -n "$found" ]]; then
    printf 'error: bundled source contains test sources or fixtures:\n%s\n' "$found" >&2
    exit 1
fi
printf '[check-voicebar-test-free] %s contains no __tests__ or *.test.ts\n' "$source_root"
