#!/usr/bin/env bash
# Fails when a VoiceBar binary still carries the dev/CI-only QA probes (Etan ruling 2,
# 2026-09-24): the probes compile only under VOICEBAR_QA, so a user build must not contain
# their socket messages or receipt variables. Exit 0 clean, 1 probes found, 2 bad input.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <VoiceBar binary>\n' "$0" >&2
  exit 2
fi
binary=$1
if [[ ! -f "$binary" ]]; then
  printf 'error: no binary at %s\n' "$binary" >&2
  exit 2
fi

markers=(
  qa_context_menu_probe
  qa_vertical_hit_probe
  QA_VOICEBAR_CONTEXT_MENU_RECEIPT_PATH
  QA_VOICEBAR_VERTICAL_HIT_RECEIPT_PATH
)
found=()
for marker in "${markers[@]}"; do
  if LC_ALL=C grep -aqF "$marker" "$binary"; then
    found+=("$marker")
  fi
done

if [[ ${#found[@]} -gt 0 ]]; then
  printf 'error: %s carries dev/CI-only QA probes: %s\n' "$binary" "${found[*]}" >&2
  printf 'A user build must not define VOICEBAR_QA (build-app.sh adds it only for VOICEBAR_QA_BUILD=1).\n' >&2
  exit 1
fi
printf '[check-voicebar-qa-free] %s carries no QA probes\n' "$binary"
