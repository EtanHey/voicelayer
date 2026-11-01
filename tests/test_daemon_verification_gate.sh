#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/daemon-verification-gate.yml"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

# Hooks may export Git state; never let fixture commits target the caller's repo.
for git_var in $(env | sed -n 's/^\(GIT_[^=]*\)=.*/\1/p'); do
    unset "$git_var"
done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

fail() {
    cat "$FIXTURE/gate.out" >&2
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Execute the actual gate, including its path filter and runtime marker checks.
awk '
    /- name: Check runtime verification marker/ { step = 1; next }
    step && /^        run: \|/ { body = 1; next }
    body && /^          / { sub(/^          /, ""); print; next }
    body && /^$/ { print; next }
    body { exit }
' "$WORKFLOW" > "$FIXTURE/gate.sh"
test -s "$FIXTURE/gate.sh"
grep -q 'fetch-depth: 0' "$WORKFLOW"

# BEGIN classifier-only controls
# Exercise the extracted gate without commits, real runtime proof or a PR body.
# The function exists only in a subshell; the real Git fixture below is unchanged.
classifier_cases=0
classifier_failures=0
classifier_case() {
    local label="$1" expected="$2" files="$3" diff_status="${4:-0}"
    local status actual ok=1
    classifier_cases=$((classifier_cases + 1))
    if (
        git() {
            if [ "$#" -ne 3 ] || [ "$1" != diff ] || [ "$2" != --name-only ] \
                || [ "$3" != "$BASE_SHA...$HEAD_SHA" ]; then
                printf 'Unexpected git invocation in classifier fixture\n' >&2
                return 97
            fi
            if [ "$GATE_FIXTURE_DIFF_STATUS" -ne 0 ]; then
                printf 'Synthetic unavailable diff\n' >&2
                return "$GATE_FIXTURE_DIFF_STATUS"
            fi
            printf '%s\n' "$GATE_FIXTURE_FILES"
        }
        export -f git
        BASE_SHA='fixture base' HEAD_SHA='fixture head' PR_BODY='' \
            GATE_FIXTURE_FILES="$files" GATE_FIXTURE_DIFF_STATUS="$diff_status" \
            TMPDIR="$FIXTURE" bash "$FIXTURE/gate.sh"
    ) > "$FIXTURE/gate.out" 2>&1; then
        status=0
    else
        status=$?
    fi
    actual="$(sed -n 's/^- //p' "$FIXTURE/gate.out")"
    if [ "$diff_status" -ne 0 ]; then
        [ "$status" -eq "$diff_status" ] && [ -z "$actual" ] \
            && grep -Fq 'Synthetic unavailable diff' "$FIXTURE/gate.out" \
            && ! grep -Fq 'runtime gate not required' "$FIXTURE/gate.out" && ok=0
    elif [ -z "$expected" ]; then
        [ "$status" -eq 0 ] && [ -z "$actual" ] \
            && grep -Fq 'No daemon/socket/MCP files changed' "$FIXTURE/gate.out" && ok=0
    else
        [ "$status" -eq 1 ] && [ "$actual" = "$expected" ] \
            && grep -Fq 'Missing runtime verification marker.' "$FIXTURE/gate.out" && ok=0
    fi
    if [ "$ok" -eq 0 ]; then
        printf 'PASS: classifier %s (gate exit %s)\n' "$label" "$status"
    else
        classifier_failures=$((classifier_failures + 1))
        printf 'FAIL: classifier %s (gate exit %s)\n' "$label" "$status" >&2
        cat "$FIXTURE/gate.out" >&2
    fi
}

ui_test='flow-bar/Tests/VoiceBarUITests/SettingsAudioPlaybackTests.swift'
classifier_case 'empty diff' '' ''
classifier_case 'documentation only' '' 'docs/daemon.md'
classifier_case 'A test path only' '' "$ui_test"
classifier_case 'nested tests and space in filename' '' \
    "$(printf '%s\n' "$ui_test" 'flow-bar/Tests/VoiceBarTests/deep/Audio Fixture.swift')"
classifier_case 'test then runtime' 'flow-bar/Sources/VoiceBar/main.swift' \
    "$(printf '%s\n' "$ui_test" 'flow-bar/Sources/VoiceBar/main.swift')"
classifier_case 'runtime then test' 'src/mcp-server.ts' \
    "$(printf '%s\n' 'src/mcp-server.ts' "$ui_test")"

# Include every existing non-VoiceBar alternative and VoiceBar build/package/bundle
# paths, plus near-miss names and unknown future VoiceBar/launchd descendants.
while IFS= read -r path; do
    classifier_case "$path remains runtime" "$path" "$path"
done <<'RUNTIME_PATHS'
flow-bar/Sources/VoiceBar/main.swift
flow-bar/build-app.sh
flow-bar/Package.swift
flow-bar/Package.resolved
flow-bar/VoiceBar.app/Contents/Info.plist
flow-bar/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
flow-bar/UnknownFutureRuntime/file
flow-bar/Tests
flow-bar/Test/Audio.swift
flow-bar/Testing/Audio.swift
flow-bar/tests/Audio.swift
flow-bar/TestsBackup/Audio.swift
flow-bar/Tests.swift
flow-bar/Tests../Audio.swift
flow-bar/Tests /Audio.swift
flow-bar/Other/Tests/Audio.swift
flow-bar/Source With Spaces.swift
launchd/com.voicelayer.plist
launchd/UnknownFutureRuntime/file
src/whisper-server.ts
src/mcp-server.ts
src/mcp-server-daemon.ts
src/mcp-daemon.ts
src/mcp-framing.ts
src/mcp-handler.ts
src/mcp-socket-owner.ts
src/mcp-tools.ts
src/daemon.ts
src/daemon-health.ts
src/log-rotation.ts
src/paths.ts
src/process-lock.ts
src/resolve-binary.ts
src/socket-future.ts
src/socket-client.ts
src/socket-handlers.ts
src/socket-protocol.ts
src/cli/voicelayer.sh
RUNTIME_PATHS

classifier_case 'existing non-runtime paths unchanged' '' \
    "$(printf '%s\n' 'tests/daemon.test.ts' 'flow-bar-other/Tests/a.swift' \
        'src/mcp-server/sub.ts' 'src/socket-directory/sub.ts' 'unclassified/future.txt')"
classifier_case 'unavailable diff fails closed' '' "$ui_test" 128
printf 'Classifier controls: %s cases, %s failures\n' "$classifier_cases" "$classifier_failures"
[ "$classifier_failures" -eq 0 ] || exit 1
# END classifier-only controls

git init -q "$FIXTURE/repo"
cd "$FIXTURE/repo"
git config user.name 'Gate Fixture'
git config user.email 'gate-fixture@example.invalid'
git config core.hooksPath /dev/null
printf 'initial\n' > README
git add README
git commit -qm 'Initial fixture'
git branch -M main
git checkout -qb pr
printf 'PR documentation\n' >> README
git commit -qam 'Documentation-only PR'
DOC_HEAD="$(git rev-parse HEAD)"
git checkout -q main
mkdir flow-bar
printf 'main release\n' > flow-bar/x
git add flow-bar/x
git commit -qm 'Main advances after PR branches'
BASE_SHA="$(git rev-parse HEAD)"
export BASE_SHA

run_gate() {
    HEAD_SHA="$1" PR_BODY="$2" TMPDIR="$FIXTURE" \
        bash "$FIXTURE/gate.sh" > "$FIXTURE/gate.out" 2>&1
}

# Show the old endpoint diff incorrectly attributes main's release to the PR.
git diff --name-only "$BASE_SHA" "$DOC_HEAD" > "$FIXTURE/old-files"
grep -Fxq 'flow-bar/x' "$FIXTURE/old-files"
printf 'PASS: old endpoint diff reproduces the stale-base false positive\n'

run_gate "$DOC_HEAD" '' || fail 'documentation-only stale-base PR must pass'
grep -Fq 'No daemon/socket/MCP files changed' "$FIXTURE/gate.out"
printf 'PASS: documentation-only stale-base PR needs no runtime marker\n'

git checkout -q pr
mkdir flow-bar
printf 'PR daemon change\n' > flow-bar/pr-change
git add flow-bar/pr-change
git commit -qm 'PR really changes VoiceBar'
DAEMON_HEAD="$(git rev-parse HEAD)"

if run_gate "$DAEMON_HEAD" ''; then
    fail 'real VoiceBar change must require a runtime marker'
fi
grep -Fxq -- '- flow-bar/pr-change' "$FIXTURE/gate.out"
grep -Fq 'Missing runtime verification marker.' "$FIXTURE/gate.out"
if grep -Fxq -- '- flow-bar/x' "$FIXTURE/gate.out"; then
    fail 'main-only release file must not be flagged alongside the PR change'
fi
printf 'PASS: real VoiceBar change is flagged without main-only files\n'

if run_gate "$DAEMON_HEAD" "Verified-Runtime: $DOC_HEAD"; then
    fail 'runtime marker for an older head must fail'
fi
grep -Fq 'Missing runtime verification marker.' "$FIXTURE/gate.out"
printf 'PASS: stale runtime marker is rejected\n'

run_gate "$DAEMON_HEAD" "Verified-Runtime: $DAEMON_HEAD" \
    || fail 'runtime marker for the actual head must pass'
grep -Fq "Found runtime verification marker for head sha $DAEMON_HEAD." "$FIXTURE/gate.out"
printf 'PASS: exact-head runtime marker is accepted\n'
