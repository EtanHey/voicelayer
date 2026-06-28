#!/usr/bin/env bash
# Release/resident version consistency guard for VoiceBar.
#
# Fails if the canonical package version drifts from the checked-in VoiceBar
# plist, Homebrew cask, exact git tag, or the resident app's stapled ticket.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${VOICEBAR_APP_PATH:-/Applications/VoiceBar.app}"
PLIST_BUDDY="${VOICEBAR_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
FAILED=0

default_tap_root() {
    local sibling
    sibling="$(cd "$PACKAGE_ROOT/.." && pwd)/homebrew-layers"
    if [[ -d "$sibling" ]]; then
        printf '%s\n' "$sibling"
    fi
}

TAP_ROOT="${VOICEBAR_VERSION_CHECK_TAP_ROOT:-${VOICEBAR_HOMEBREW_TAP_ROOT:-$(default_tap_root)}}"

err() {
    printf '[voicelayer-version-check] ERROR: %s\n' "$*" >&2
}

read_json_version() {
    local path="$1"
    bun -e 'const path = process.argv[1]; console.log(JSON.parse(await Bun.file(path).text()).version ?? "")' "$path"
}

read_plist_string() {
    local plist_path="$1"
    local key="$2"
    if [[ -x "$PLIST_BUDDY" ]]; then
        "$PLIST_BUDDY" -c "Print :$key" "$plist_path"
        return
    fi
    awk -v key="$key" '
        $0 ~ "<key>" key "</key>" {
            getline
            sub(/^[[:space:]]*<string>/, "")
            sub(/<\/string>[[:space:]]*$/, "")
            print
            exit
        }
    ' "$plist_path"
}

extract_cask_version() {
    local cask_path="$1"
    awk '
        /^[[:space:]]*version "/ {
            gsub(/"/, "", $2)
            print $2
            exit
        }
    ' "$cask_path"
}

current_git_tag() {
    if [[ -n "${VOICEBAR_VERSION_CHECK_GIT_TAG:-}" ]]; then
        printf '%s\n' "$VOICEBAR_VERSION_CHECK_GIT_TAG"
        return
    fi
    git -C "$PACKAGE_ROOT" describe --tags --exact-match 2>/dev/null || true
}

require_file() {
    local label="$1"
    local path="$2"
    if [[ ! -f "$path" ]]; then
        err "$label not found: $path"
        FAILED=1
    fi
}

require_dir() {
    local label="$1"
    local path="$2"
    if [[ ! -d "$path" ]]; then
        err "$label not found: $path"
        FAILED=1
    fi
}

require_equal() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    if [[ "$actual" != "$expected" ]]; then
        err "$label is '$actual', expected '$expected'"
        FAILED=1
    fi
}

verify_stapled_resident_app() {
    if ! xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
        err "resident VoiceBar.app does not have a valid stapled notarization ticket: $APP_PATH"
        FAILED=1
    fi
}

if [[ -z "$TAP_ROOT" ]]; then
    err "Homebrew tap root is required. Set VOICEBAR_VERSION_CHECK_TAP_ROOT or VOICEBAR_HOMEBREW_TAP_ROOT."
    exit 2
fi

PACKAGE_JSON="$PACKAGE_ROOT/package.json"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
CASK_PATH="$TAP_ROOT/Casks/voicebar.rb"

require_file "repo package.json" "$PACKAGE_JSON"
require_dir "resident VoiceBar.app" "$APP_PATH"
require_file "resident VoiceBar Info.plist" "$INFO_PLIST"
require_file "Homebrew cask" "$CASK_PATH"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

canonical_version="$(read_json_version "$PACKAGE_JSON")"
plist_short_version="$(read_plist_string "$INFO_PLIST" "CFBundleShortVersionString")"
plist_build_version="$(read_plist_string "$INFO_PLIST" "CFBundleVersion")"
cask_version="$(extract_cask_version "$CASK_PATH")"
git_tag="$(current_git_tag)"
expected_git_tag="v$canonical_version"

require_equal "Info.plist CFBundleShortVersionString" "$plist_short_version" "$canonical_version"
require_equal "Info.plist CFBundleVersion" "$plist_build_version" "$canonical_version"
require_equal "Casks/voicebar.rb version" "$cask_version" "$canonical_version"
require_equal "git tag" "$git_tag" "$expected_git_tag"
verify_stapled_resident_app

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

printf '[voicelayer-version-check] PASS: VoiceBar %s version and notarization guard\n' "$canonical_version"
