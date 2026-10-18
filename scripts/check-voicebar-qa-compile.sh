#!/usr/bin/env bash
# Compile the QA-only UIE2E sources the way voicebar-ui-e2e.sh builds them (#416 C1).
# CI never built with these flags, so a QA-only source could stop compiling unnoticed.
# Flags come from build-app.sh's own configure_qa_swift_flags, so they cannot drift.
# hide1 must compile on main alone; gate2246's capture cases also need #410's APIs.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
# shellcheck source=../flow-bar/build-app.sh
VOICEBAR_BUILD_APP_SOURCE_ONLY=1 source flow-bar/build-app.sh
for config in hide1:0 gate2246:1; do
  scenario=${config%%:*}
  VOICEBAR_QA_BUILD=1 VOICEBAR_UIE2E_GATE2245=1 VOICEBAR_UIE2E_GATE2246_CAPTURE=${config#*:} \
    VOICEBAR_UIE2E_FOCUSED_338=0 configure_qa_swift_flags > /dev/null
  command=(swift build -c release --package-path flow-bar --product VoiceBar "${QA_SWIFT_FLAGS[@]}")
  if [[ ${VOICEBAR_QA_COMPILE_DRY_RUN:-0} == 1 ]]; then
    echo "$scenario: ${command[*]}"
    continue
  fi
  echo "[qa-compile] $scenario: ${command[*]}" >&2
  "${command[@]}"
done
