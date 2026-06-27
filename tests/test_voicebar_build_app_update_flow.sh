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

test_target_app_pid_discovery_accepts_symlink_resolved_executable() {
    local tmp_dir
    local actual_app
    local symlink_app
    local resolved_executable
    tmp_dir="$(mktemp -d)"
    actual_app="$tmp_dir/VoiceBarActual.app"
    symlink_app="$tmp_dir/VoiceBar.app"
    mkdir -p "$actual_app/Contents/MacOS"
    : > "$actual_app/Contents/MacOS/VoiceBar"
    ln -s "$actual_app" "$symlink_app"

    APP_DIR="$symlink_app"
    resolved_executable="$(cd "$actual_app/Contents/MacOS" && pwd -P)/VoiceBar"
    # shellcheck disable=SC2034
    VOICEBAR_TEST_PROCESS_TABLE="777 1 $resolved_executable"

    local actual
    actual="$(voicebar_target_app_pids | tr '\n' ' ' | sed 's/ $//')"

    unset VOICEBAR_TEST_PROCESS_TABLE
    rm -rf "$tmp_dir"

    assert_eq "777" "$actual" "symlink-resolved target app pid"
}

test_relaunch_verification_requires_target_app_process() {
    APP_DIR="/Applications/VoiceBar.app"

    # A fallback app with the same bundle id must not satisfy relaunch
    # verification for the canonical /Applications target.
    # shellcheck disable=SC2034
    VOICEBAR_TEST_BUNDLE_PIDS=$'100'
    # shellcheck disable=SC2034
    VOICEBAR_TEST_TARGET_APP_PIDS=""
    if voicebar_relaunch_instance_status >/dev/null 2>&1; then
        unset VOICEBAR_TEST_BUNDLE_PIDS VOICEBAR_TEST_TARGET_APP_PIDS
        fail "relaunch verification must reject same-bundle fallback without target app PID"
    fi

    # A target-path process that is not the single bundle-id process is also
    # unsafe; it means the fallback and canonical app are both present.
    # shellcheck disable=SC2034
    VOICEBAR_TEST_BUNDLE_PIDS=$'100'
    # shellcheck disable=SC2034
    VOICEBAR_TEST_TARGET_APP_PIDS=$'200'
    if voicebar_relaunch_instance_status >/dev/null 2>&1; then
        unset VOICEBAR_TEST_BUNDLE_PIDS VOICEBAR_TEST_TARGET_APP_PIDS
        fail "relaunch verification must reject bundle/target PID mismatch"
    fi

    # The only passing state is one bundle-id process and that same PID running
    # from APP_DIR/Contents/MacOS/VoiceBar with the command socket created.
    # shellcheck disable=SC2034
    VOICEBAR_TEST_BUNDLE_PIDS=$'200'
    # shellcheck disable=SC2034
    VOICEBAR_TEST_TARGET_APP_PIDS=$'200'
    # shellcheck disable=SC2034
    VOICEBAR_TEST_SOCKET_READY=1
    voicebar_relaunch_instance_status >/dev/null || {
        unset VOICEBAR_TEST_BUNDLE_PIDS VOICEBAR_TEST_TARGET_APP_PIDS VOICEBAR_TEST_SOCKET_READY
        fail "relaunch verification should accept the single canonical target PID"
    }

    # A launch-suspended target PID is not enough; VoiceBar must have entered
    # app init far enough to bind its command socket.
    # shellcheck disable=SC2034
    VOICEBAR_TEST_BUNDLE_PIDS=$'200'
    # shellcheck disable=SC2034
    VOICEBAR_TEST_TARGET_APP_PIDS=$'200'
    # shellcheck disable=SC2034
    VOICEBAR_TEST_SOCKET_READY=0
    if voicebar_relaunch_instance_status >/dev/null 2>&1; then
        unset VOICEBAR_TEST_BUNDLE_PIDS VOICEBAR_TEST_TARGET_APP_PIDS VOICEBAR_TEST_SOCKET_READY
        fail "relaunch verification must reject a target PID when the command socket is missing"
    fi

    unset VOICEBAR_TEST_BUNDLE_PIDS VOICEBAR_TEST_TARGET_APP_PIDS VOICEBAR_TEST_SOCKET_READY
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

test_developer_id_signature_guard_allows_apple_development_with_dangerous_override() {
    APP_DIR="/Applications/VoiceBar.app"
    VOICEBAR_ALLOW_DANGEROUS_DEV_RESIDENT_INSTALL=1
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
    verify_developer_id_signature || {
        PATH="$old_path"
        rm -rf "$bin_dir"
        unset VOICEBAR_ALLOW_DANGEROUS_DEV_RESIDENT_INSTALL
        fail "dangerous override should allow Apple Development signature verification"
    }
    PATH="$old_path"
    rm -rf "$bin_dir"
    unset VOICEBAR_ALLOW_DANGEROUS_DEV_RESIDENT_INSTALL
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
    printf 'Authority=Developer ID Application: Etan Heyman (PPN23G925Y)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=PPN23G925Y\n' >&2
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

test_developer_id_signature_guard_rejects_partial_chain() {
    APP_DIR="/tmp/VoiceBar-Test.app"
    local bin_dir
    bin_dir="$(mktemp -d)"
    cat > "$bin_dir/codesign" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"-d -r-"* ]]; then
    printf 'designated => identifier "com.voicelayer.voicebar" and anchor apple generic and certificate leaf[subject.OU] = "PPN23G925Y" and certificate leaf[subject.CN] = "Developer ID Application: Etan Heyman (PPN23G925Y)"\n' >&2
elif [[ "$*" == *"-dvvv"* || "$*" == *"-dv"* ]]; then
    printf 'Authority=Developer ID Application: Etan Heyman (PPN23G925Y)\nTeamIdentifier=PPN23G925Y\n' >&2
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
        fail "Developer ID guard must reject partial signature chains"
    fi
    PATH="$old_path"
    rm -rf "$bin_dir"
}

test_resident_app_install_rejects_apple_development_without_dangerous_override() {
    APP_DIR="/Applications/VoiceBar.app"
    local old_sign_identity="$SIGN_IDENTITY"
    local old_required_prefix="$VOICEBAR_REQUIRED_SIGNING_PREFIX"
    local old_required_team="$VOICEBAR_REQUIRED_TEAM_ID"
    SIGN_IDENTITY="Apple Development: Etan Heyman (DXHB5E7P2D)"
    VOICEBAR_REQUIRED_SIGNING_PREFIX="Apple Development"
    VOICEBAR_REQUIRED_TEAM_ID="DXHB5E7P2D"
    unset VOICEBAR_ALLOW_DANGEROUS_DEV_RESIDENT_INSTALL || true

    local bin_dir
    bin_dir="$(mktemp -d)"
    cat > "$bin_dir/security" <<'SH'
#!/usr/bin/env bash
printf '  1) ABCDEF "Apple Development: Etan Heyman (DXHB5E7P2D)"\n'
SH
    chmod 755 "$bin_dir/security"

    local old_path="$PATH"
    PATH="$bin_dir:$PATH"
    if validate_signing_identity; then
        PATH="$old_path"
        rm -rf "$bin_dir"
        fail "resident /Applications install must reject Apple Development signing without dangerous override"
    fi
    PATH="$old_path"
    rm -rf "$bin_dir"

    # shellcheck disable=SC2034 # Reset globals used by sourced build-app helpers.
    SIGN_IDENTITY="$old_sign_identity"
    # shellcheck disable=SC2034 # Reset globals used by sourced build-app helpers.
    VOICEBAR_REQUIRED_SIGNING_PREFIX="$old_required_prefix"
    # shellcheck disable=SC2034 # Reset globals used by sourced build-app helpers.
    VOICEBAR_REQUIRED_TEAM_ID="$old_required_team"
}

test_resident_app_install_allows_apple_development_with_dangerous_override() {
    APP_DIR="/Applications/VoiceBar.app"
    local old_sign_identity="$SIGN_IDENTITY"
    local old_required_prefix="$VOICEBAR_REQUIRED_SIGNING_PREFIX"
    local old_required_team="$VOICEBAR_REQUIRED_TEAM_ID"
    SIGN_IDENTITY="Apple Development: Etan Heyman (DXHB5E7P2D)"
    VOICEBAR_REQUIRED_SIGNING_PREFIX="Developer ID Application"
    VOICEBAR_REQUIRED_TEAM_ID="PPN23G925Y"
    # shellcheck disable=SC2034 # Used by sourced build-app helper.
    VOICEBAR_ALLOW_DANGEROUS_DEV_RESIDENT_INSTALL=1

    local bin_dir
    bin_dir="$(mktemp -d)"
    cat > "$bin_dir/security" <<'SH'
#!/usr/bin/env bash
printf '  1) ABCDEF "Apple Development: Etan Heyman (DXHB5E7P2D)"\n'
SH
    chmod 755 "$bin_dir/security"

    local old_path="$PATH"
    PATH="$bin_dir:$PATH"
    validate_signing_identity || {
        PATH="$old_path"
        rm -rf "$bin_dir"
        unset VOICEBAR_ALLOW_DANGEROUS_DEV_RESIDENT_INSTALL
        fail "dangerous override should allow intentional Apple Development resident install"
    }
    PATH="$old_path"
    rm -rf "$bin_dir"
    unset VOICEBAR_ALLOW_DANGEROUS_DEV_RESIDENT_INSTALL

    # shellcheck disable=SC2034 # Reset globals used by sourced build-app helpers.
    SIGN_IDENTITY="$old_sign_identity"
    # shellcheck disable=SC2034 # Reset globals used by sourced build-app helpers.
    VOICEBAR_REQUIRED_SIGNING_PREFIX="$old_required_prefix"
    # shellcheck disable=SC2034 # Reset globals used by sourced build-app helpers.
    VOICEBAR_REQUIRED_TEAM_ID="$old_required_team"
}

test_build_strips_security_xattrs_before_signing() {
    APP_DIR="/tmp/VoiceBar-Test.app"
    local bin_dir
    local log_file
    bin_dir="$(mktemp -d)"
    log_file="$bin_dir/xattr.log"
    cat > "$bin_dir/xattr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log_file"
exit 0
SH
    chmod 755 "$bin_dir/xattr"

    local old_path="$PATH"
    PATH="$bin_dir:$PATH"
    strip_voicebar_security_xattrs
    PATH="$old_path"

    grep -Fq -- "-dr com.apple.quarantine $APP_DIR" "$log_file" || {
        rm -rf "$bin_dir"
        fail "build-app.sh must strip quarantine xattrs before signing"
    }
    grep -Fq -- "-dr com.apple.macl $APP_DIR" "$log_file" || {
        rm -rf "$bin_dir"
        fail "build-app.sh must strip macl xattrs before signing"
    }
    rm -rf "$bin_dir"
}

test_parse_no_stop_and_no_relaunch_flags
test_target_pid_discovery_is_root_bundle_plus_descendants_only
test_target_app_pid_discovery_accepts_symlink_resolved_executable
test_relaunch_verification_requires_target_app_process
test_no_broad_process_killers
test_update_delegates_relaunch_to_build_app
test_developer_id_signature_guard_rejects_apple_development
test_developer_id_signature_guard_allows_apple_development_with_dangerous_override
test_developer_id_signature_guard_accepts_developer_id
test_developer_id_signature_guard_rejects_partial_chain
test_resident_app_install_rejects_apple_development_without_dangerous_override
test_resident_app_install_allows_apple_development_with_dangerous_override
test_build_strips_security_xattrs_before_signing

printf 'PASS: VoiceBar build/update flow shell tests\n'
