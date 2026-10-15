#!/usr/bin/env bash
# UI-only runner. --build-only is the only mode permitted on an occupied Mac.
set -euo pipefail
usage() { echo "usage: $0 --output NEW_DIRECTORY [--build-only]"; }
build_only=0
output=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; output=$2; shift 2 ;;
    --build-only) build_only=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$output" ]] || { usage >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$(dirname "$output")"
mkdir "$output" # Refuse to overwrite a previous run or any of its evidence.
output=$(cd "$output" && pwd)
for tool in xcodebuild xcrun swift python3 bun; do command -v "$tool" >/dev/null || { echo "FAIL prerequisite: $tool"; exit 1; }; done
# /tmp is deliberately short: macOS sockaddr_un has a 104-byte limit.
sandbox=$(mktemp -d /tmp/vl-ui-XXXXXX)
printf '%s\n' voicebar-ui-e2e-v1 > "$sandbox/.uie2e-sandbox"
mkdir "$sandbox/home"
printf '%s\n' "$sandbox" > "$output/sandbox-path.txt"
# Keep the sandbox, QA app, settings and receipts for failure analysis. No broad cleanup/kill.
app="$sandbox/VoiceBarQA.app"
if [[ $build_only == 0 ]]; then
  /usr/bin/osascript -e 'set volume output muted true'
  [[ $(/usr/bin/osascript -e 'output muted of (get volume settings)') == true ]] || { echo 'FAIL output mute unconfirmed'; exit 1; }
fi
# This never stops, swaps or launches the installed app, and never installs the F5 relay.
VOICEBAR_QA_BUILD=1 VOICEBAR_UIE2E_ADHOC=1 VOICEBAR_CODESIGN_IDENTITY=- \
  bash "$repo/flow-bar/build-app.sh" --install-path "$app" --no-stop --no-relaunch > "$output/app-build.log" 2>&1 || {
    echo "FAIL QA app build (see $output/app-build.log)"; exit 1;
  }
# Capability metadata follows the compiled tree; older main can still build the future UI steps.
python3 - "$repo" "$app" <<'PYMETA'
import pathlib, plistlib, sys
repo, app = map(pathlib.Path, sys.argv[1:])
p = app / 'Contents/Info.plist'
data = plistlib.loads(p.read_bytes())
source = (repo / 'flow-bar/Sources/VoiceBarUI/VoiceState.swift').read_text()
assert data['VoiceBarUIE2EOnly'] is True
assert data['CFBundleIdentifier'] == 'com.voicelayer.voicebar.uie2e'
assert 'CFBundleURLTypes' not in data
data['UIE2EPasteFeedback'] = 'Partially inserted — full transcript kept in History.' in source
p.write_bytes(plistlib.dumps(data))
PYMETA
/usr/bin/codesign --force --sign - "$app" > "$output/qa-sign.log" 2>&1
xcodebuild build-for-testing -project "$repo/flow-bar/UIE2E/VoiceBarUIE2E.xcodeproj" -scheme VoiceBarUIE2E \
  -destination 'platform=macOS' -derivedDataPath "$output/DerivedData" > "$output/build-for-testing.log" 2>&1 || {
    echo "FAIL build-for-testing (see $output/build-for-testing.log)"; exit 1;
  }
echo 'PASS build-for-testing (UI execution NOT_PROVEN)'
[[ $build_only == 0 ]] || exit 0
python3 "$repo/scripts/voicebar-ui-e2e-results.py" configure "$output" "$app" "$sandbox"
# Reconfirm immediately before XCUITest takes the screen. Leave output muted after the run.
[[ $(/usr/bin/osascript -e 'output muted of (get volume settings)') == true ]] || { echo 'FAIL output mute changed'; exit 1; }
status=0
# Default recording is part of the run, not an optional adapter. Build-only exits above.
python3 "$repo/scripts/voicebar-ui-e2e-run.py" "$output" || status=$?
export_status=0
python3 "$repo/scripts/voicebar-ui-e2e-results.py" export "$output" "$sandbox" || export_status=$?
[[ $status == 0 && $export_status == 0 ]] || { echo "FAIL UIE2E: xcodebuild=$status export=$export_status"; exit 1; }
echo "PASS UIE2E: $output/screenshots/index.html"
