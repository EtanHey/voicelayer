#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/flow-bar/build-app.sh"
UPDATE_SCRIPT="$ROOT_DIR/scripts/voicelayer-update.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        fail "$label: expected '$expected', got '$actual'"
    fi
}

if ! grep -q 'VOICEBAR_BUILD_APP_SOURCE_ONLY' "$BUILD_SCRIPT"; then
    fail "build-app.sh must support VOICEBAR_BUILD_APP_SOURCE_ONLY for non-invasive tests"
fi

# shellcheck disable=SC2034
VOICEBAR_BUILD_APP_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$BUILD_SCRIPT"

test_parse_no_stop_and_no_relaunch_flags() {
    APP_DIR="/Applications/VoiceBar.app"
    STOP_RUNNING=1
    RELAUNCH_APP=1

    parse_build_app_args --no-stop --no-relaunch --install-path /tmp/VoiceBar-Test.app

    assert_eq "/tmp/VoiceBar-Test.app" "$APP_DIR" "install path"
    assert_eq "0" "$STOP_RUNNING" "--no-stop disables stopping"
    assert_eq "0" "$RELAUNCH_APP" "--no-relaunch disables relaunch"
}

test_target_pid_discovery_is_root_bundle_plus_descendants_only() {
    # shellcheck disable=SC2034
    VOICEBAR_TEST_BUNDLE_PIDS=$'100\n300'
    # shellcheck disable=SC2034
    VOICEBAR_TEST_PS_PID_PPID=$'100 1\n101 100\n102 101\n200 1\n201 200\n300 1\n301 300'

    local actual
    actual="$(voicebar_target_pids | tr '\n' ' ' | sed 's/ $//')"

    unset VOICEBAR_TEST_BUNDLE_PIDS
    unset VOICEBAR_TEST_PS_PID_PPID

    assert_eq "100 101 102 300 301" "$actual" "target pids"
}

test_no_broad_process_killers() {
    if grep -Eq '\b(pkill|killall)\b' "$BUILD_SCRIPT"; then
        fail "build-app.sh must not use broad pkill/killall process matching"
    fi
}

test_update_delegates_relaunch_to_build_app() {
    if grep -q 'restart_voicebar_stack' "$UPDATE_SCRIPT"; then
        fail "voicelayer-update.sh should delegate VoiceBar relaunch to build-app.sh"
    fi
    if ! grep -q -- '--no-relaunch' "$UPDATE_SCRIPT"; then
        fail "voicelayer-update.sh should pass through --no-relaunch"
    fi
    if ! grep -q -- '--no-stop' "$UPDATE_SCRIPT"; then
        fail "voicelayer-update.sh should pass through --no-stop"
    fi
}

test_developer_id_signature_guard_rejects_apple_development() {
    APP_DIR="/tmp/VoiceBar-Test.app"
    local bin_dir
    bin_dir="$(mktemp -d)"
    cat > "$bin_dir/codesign" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"-d -r-"* ]]; then
    printf 'designated => identifier "com.voicelayer.voicebar" and anchor apple generic and certificate leaf[subject.OU] = "DXHB5E7P2D" and certificate leaf[subject.CN] = "Apple Development: Etan Heyman (DXHB5E7P2D)"\n' >&2
elif [[ "$*" == *"-dvvv"* || "$*" == *"-dv"* ]]; then
    printf 'Authority=Apple Development: Etan Heyman (DXHB5E7P2D)\nTeamIdentifier=DXHB5E7P2D\n' >&2
else
    exit 2
fi
SH
    chmod 755 "$bin_dir/codesign"

    local old_path="$PATH"
    PATH="$bin_dir:$PATH"
    if verify_developer_id_signature; then
        PATH="$old_path"
        rm -rf "$bin_dir"
        fail "Developer ID guard must reject Apple Development signatures"
    fi
    PATH="$old_path"
    rm -rf "$bin_dir"
}

test_developer_id_signature_guard_accepts_developer_id() {
    APP_DIR="/tmp/VoiceBar-Test.app"
    local bin_dir
    bin_dir="$(mktemp -d)"
    cat > "$bin_dir/codesign" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"-d -r-"* ]]; then
    printf 'designated => identifier "com.voicelayer.voicebar" and anchor apple generic and certificate leaf[subject.OU] = "PPN23G925Y" and certificate leaf[subject.CN] = "Developer ID Application: Etan Heyman (PPN23G925Y)"\n' >&2
elif [[ "$*" == *"-dvvv"* || "$*" == *"-dv"* ]]; then
    printf 'Authority=Developer ID Application: Etan Heyman (PPN23G925Y)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=PPN23G925Y\n' >&2
else
    exit 2
fi
SH
    chmod 755 "$bin_dir/codesign"

    local old_path="$PATH"
    PATH="$bin_dir:$PATH"
    verify_developer_id_signature || {
        PATH="$old_path"
        rm -rf "$bin_dir"
        fail "Developer ID guard must accept Developer ID Application signatures"
    }
    PATH="$old_path"
    rm -rf "$bin_dir"
}

test_parse_no_stop_and_no_relaunch_flags
test_target_pid_discovery_is_root_bundle_plus_descendants_only
test_no_broad_process_killers
test_update_delegates_relaunch_to_build_app
test_developer_id_signature_guard_rejects_apple_development
test_developer_id_signature_guard_accepts_developer_id

printf 'PASS: VoiceBar build/update flow shell tests\n'
