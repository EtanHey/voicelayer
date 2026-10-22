#!/usr/bin/env bash
# UI-only runner. --build-only is the only mode permitted on an occupied Mac.
set -euo pipefail
usage() { echo "usage: $0 [--output NEW_DIRECTORY] [--build-only] [--scenario full|focused-338|hide1|gate2246]"; }
build_only=0
scenario=full
focused_338=0
output=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; output=$2; shift 2 ;;
    --build-only) build_only=1; shift ;;
    --scenario) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; scenario=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$scenario" in
  full) ;;
  focused-338) focused_338=1 ;;
  hide1) export VOICEBAR_UIE2E_GATE2245=1 VOICEBAR_UIE2E_GATE2246_CAPTURE=0 ;;
  gate2246) export VOICEBAR_UIE2E_GATE2245=1 VOICEBAR_UIE2E_GATE2246_CAPTURE=1 ;;
  *) echo "FAIL unknown scenario: $scenario (expected full, focused-338, hide1 or gate2246)" >&2; exit 2 ;;
esac
repo=$(cd "$(dirname "$0")/.." && pwd)
output=${output:-"$repo/.build.noindex/ui-e2e/$(date -u +%Y%m%dT%H%M%S)-$$"}
source "$repo/scripts/lib/noindex-path.sh"
require_noindex_path "$output"
mkdir -p "$(dirname "$output")"
mkdir "$output" # Refuse to overwrite a previous run or any of its evidence.
output=$(cd "$output" && pwd)
derived_data="$repo/.build.noindex/DerivedData/$(basename "$output")-$$"
printf '%s\n' "$derived_data" > "$output/derived-data-path.txt"
python3 "$repo/scripts/voicebar-ui-e2e-results.py" scenario "$output" --scenario "$scenario"
for tool in xcodebuild xcrun swift python3 bun; do command -v "$tool" >/dev/null || { echo "FAIL prerequisite: $tool"; exit 1; }; done
# The display-only UIE2E app does not start socket servers; keep its bundle in the worktree.
# The basename also namespaces distributed fixture/boundary notifications and defaults.
sandbox="$output/vl-ui-$(python3 -c 'import uuid; print(uuid.uuid4().hex)').noindex"
mkdir "$sandbox"
printf '%s\n' voicebar-ui-e2e-v1 > "$sandbox/.uie2e-sandbox"
mkdir "$sandbox/home"
printf '%s\n' "$sandbox" > "$output/sandbox-path.txt"
# Keep the sandbox, QA app, settings and receipts for failure analysis. No broad cleanup/kill.
app="$sandbox/VoiceBarQA.app"
# XCUITest audio must be silent. The guard records the prior mute state and restores it
# from EXIT/INT/TERM traps, so success, failure and interrupt never leave the Mac muted.
source "$repo/scripts/lib/output-mute-guard.sh"
if [[ $build_only == 0 ]]; then
  output_mute_guard_begin || exit 1
fi
# This never stops, swaps or launches the installed app, and never installs the F5 relay.
VOICEBAR_QA_BUILD=1 VOICEBAR_UIE2E_FOCUSED_338=$focused_338 VOICEBAR_UIE2E_ADHOC=1 VOICEBAR_CODESIGN_IDENTITY=- \
  bash "$repo/flow-bar/build-app.sh" --install-path "$app" --no-stop --no-relaunch > "$output/app-build.log" 2>&1 || {
    echo "FAIL QA app build (see $output/app-build.log)"; exit 1;
  }
# Capability metadata follows the compiled tree; older main can still build the future UI steps.
python3 - "$repo" "$app" <<'PYMETA'
import pathlib, plistlib, re, sys
repo, app = map(pathlib.Path, sys.argv[1:])
p = app / 'Contents/Info.plist'
data = plistlib.loads(p.read_bytes())
source = (repo / 'flow-bar/Sources/VoiceBarUI/VoiceState.swift').read_text()
assert data['VoiceBarUIE2EOnly'] is True
assert data['CFBundleIdentifier'] == 'com.voicelayer.voicebar.uie2e'
assert 'CFBundleURLTypes' not in data
# #338 and P1e share outcome declarations; P1e moves/shortens the display copy.
# Match declarations in the product enum, ignoring comments and string mentions.
source = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', ' ', source, flags=re.S)
outcomes = re.search(r'\benum\s+VoicePasteOutcome\b[^{}]*\{([^{}]*)\}', source)
data['UIE2EPasteFeedback'] = bool(outcomes and all(
    re.search(r'\bcase\s+' + name + r'\b', outcomes.group(1))
    for name in ('notInserted', 'unverified', 'partial')
))
import os
data['UIE2EGate2245'] = os.environ.get('VOICEBAR_UIE2E_GATE2245') == '1'
p.write_bytes(plistlib.dumps(data))
PYMETA
/usr/bin/codesign --force --sign - "$app" > "$output/qa-sign.log" 2>&1
# Compile the display-only recorder in build-only too, without executing it.
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" "$repo/scripts/voicebar-ui-e2e-capture.swift" \
  -o "$output/voicebar-ui-e2e-capture" > "$output/capture-build.log" 2>&1 || {
    echo "FAIL screen recorder build (see $output/capture-build.log)"; exit 1;
  }
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$repo/scripts/voicebar-ui-e2e-visibility.swift" -o "$output/voicebar-ui-e2e-visibility" \
  > "$output/visibility-build.log" 2>&1 || { echo 'FAIL visibility helper build'; exit 1; }
xcodebuild build-for-testing -project "$repo/flow-bar/UIE2E/VoiceBarUIE2E.xcodeproj" -scheme VoiceBarUIE2E \
  -destination 'platform=macOS' -derivedDataPath "$derived_data" > "$output/build-for-testing.log" 2>&1 || {
    echo "FAIL build-for-testing (see $output/build-for-testing.log)"; exit 1;
  }
for helper in resident permissions; do
  xcrun swiftc "$repo/scripts/voicebar-ui-e2e-$helper.swift" -o "$output/voicebar-ui-e2e-$helper" \
    > "$output/$helper-build.log" 2>&1 || { echo "FAIL $helper helper build"; exit 1; }
done
echo 'PASS build-for-testing (UI execution NOT_PROVEN)'
# Every GATE2245 build constructs the real AppDelegate, so every one needs the tripwire.
if [[ ${VOICEBAR_UIE2E_GATE2245:-0} == 1 ]]; then
  python3 "$repo/scripts/voicebar-ui-e2e-guard-proof.py" build "$output"
fi
[[ $build_only == 0 ]] || exit 0
# The shell guard owns host mute restoration; the supervisor owns run safety and cleanup.
output_mute_guard_confirm || { echo 'FAIL output mute changed'; exit 1; }
python3 "$repo/scripts/voicebar-ui-e2e-supervisor.py" "$output" --scenario "$scenario"
