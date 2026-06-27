#!/usr/bin/env bash
# Verify a VoiceBar release artifact before publishing cask checksum inputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=""
APP_PATH=""
ZIP_PATH=""
SKIP_TAP_CHECK=0
TAP_ROOT="${VOICEBAR_HOMEBREW_TAP_ROOT:-}"
PLIST_BUDDY="${VOICEBAR_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
REQUIRED_TEAM_ID="${VOICEBAR_REQUIRED_TEAM_ID:-PPN23G925Y}"

usage() {
    cat <<'EOF'
Usage: scripts/verify-voicebar-release.sh --version VERSION --app PATH --zip PATH [--tap-root PATH] [--skip-tap-check]

Fails if the VoiceBar release artifact, bundled package metadata, MCP version
source, signing identity, notarization ticket, or Homebrew tap versions drift
from the canonical package.json release version.

Use --skip-tap-check only while producing a new artifact checksum before the
matching Homebrew tap bump exists. Run again without it after the tap is updated.
EOF
}

err() {
    printf '[verify-voicebar-release] ERROR: %s\n' "$*" >&2
}

read_json_version() {
    local path="$1"
    bun -e 'const path = process.argv[1]; console.log(JSON.parse(await Bun.file(path).text()).version ?? "")' "$path"
}

read_plist_string() {
    local plist_path="$1"
    local key="$2"
    if [ -x "$PLIST_BUDDY" ]; then
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

extract_formula_version() {
    local formula_path="$1"
    local url
    url="$(grep -E 'voicelayer-mcp-[0-9][^/]*\.tgz' "$formula_path" | head -n 1 || true)"
    if [ -z "$url" ]; then
        return 0
    fi
    printf '%s\n' "$url" | sed -E 's/.*voicelayer-mcp-([^/"]+)\.tgz.*/\1/'
}

require_equal() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" != "$expected" ]; then
        err "$label is '$actual', expected '$expected'"
        return 1
    fi
}

require_file() {
    local label="$1"
    local path="$2"
    if [ ! -f "$path" ]; then
        err "$label not found: $path"
        return 1
    fi
}

require_dir() {
    local label="$1"
    local path="$2"
    if [ ! -d "$path" ]; then
        err "$label not found: $path"
        return 1
    fi
}

verify_mcp_version_source() {
    local source
    for source in "$PACKAGE_ROOT/src/mcp-server.ts" "$PACKAGE_ROOT/src/mcp-handler.ts"; do
        if grep -Eq 'version:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$source"; then
            err "MCP serverInfo version is hardcoded in ${source#"$PACKAGE_ROOT"/}"
            return 1
        fi
        if ! grep -F "PACKAGE_VERSION" "$source" >/dev/null; then
            err "MCP serverInfo version source is not wired to PACKAGE_VERSION in ${source#"$PACKAGE_ROOT"/}"
            return 1
        fi
    done
}

verify_signature() {
    local requirements
    local details

    if ! requirements="$(codesign -d -r- "$APP_PATH" 2>&1)"; then
        err "could not read app designated requirement"
        printf '%s\n' "$requirements" >&2
        return 1
    fi
    if ! details="$(codesign -dvvv "$APP_PATH" 2>&1)"; then
        err "could not read app code signature details"
        printf '%s\n' "$details" >&2
        return 1
    fi

    if printf '%s\n' "$details" | grep -F "Authority=Apple Development:" >/dev/null; then
        err "app is Apple Development signed"
        printf '%s\n' "$details" >&2
        return 1
    fi
    if ! printf '%s\n' "$requirements" | grep -F "$REQUIRED_TEAM_ID" >/dev/null; then
        err "app designated requirement is not pinned to Developer ID team $REQUIRED_TEAM_ID"
        printf '%s\n' "$requirements" >&2
        return 1
    fi
    if ! printf '%s\n' "$details" | grep -F "Authority=Developer ID Application:" >/dev/null; then
        err "app is not signed with Developer ID Application"
        printf '%s\n' "$details" >&2
        return 1
    fi
    if ! printf '%s\n' "$details" | grep -F "TeamIdentifier=$REQUIRED_TEAM_ID" >/dev/null; then
        err "app TeamIdentifier is not $REQUIRED_TEAM_ID"
        printf '%s\n' "$details" >&2
        return 1
    fi
    if ! printf '%s\n' "$details" | grep -F "Runtime Version=" >/dev/null; then
        err "app signature does not show hardened runtime"
        printf '%s\n' "$details" >&2
        return 1
    fi
}

verify_stapled_ticket() {
    if ! xcrun stapler validate "$APP_PATH"; then
        err "app does not have a valid stapled notarization ticket"
        return 1
    fi
}

verify_no_security_xattrs() {
    if ! command -v xattr >/dev/null 2>&1; then
        err "xattr command not found; cannot verify release security metadata"
        return 1
    fi

    local xattr_output
    local restricted_xattrs
    xattr_output="$(xattr -lr "$APP_PATH" "$ZIP_PATH" 2>/dev/null || true)"
    restricted_xattrs="$(
        printf '%s\n' "$xattr_output" \
            | grep -E '(^|[[:space:]])com\.apple\.(macl|quarantine)(:|$)' || true
    )"
    if [ -n "$restricted_xattrs" ]; then
        err "release artifact contains path/security extended attributes"
        printf '%s\n' "$restricted_xattrs" >&2
        return 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ $# -lt 2 ]]; then
                err "--version requires a value"
                exit 2
            fi
            VERSION="$2"
            shift 2
            ;;
        --app)
            if [[ $# -lt 2 ]]; then
                err "--app requires a value"
                exit 2
            fi
            APP_PATH="$2"
            shift 2
            ;;
        --zip)
            if [[ $# -lt 2 ]]; then
                err "--zip requires a value"
                exit 2
            fi
            ZIP_PATH="$2"
            shift 2
            ;;
        --tap-root)
            if [[ $# -lt 2 ]]; then
                err "--tap-root requires a value"
                exit 2
            fi
            TAP_ROOT="$2"
            shift 2
            ;;
        --skip-tap-check)
            SKIP_TAP_CHECK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$VERSION" ] || [ -z "$APP_PATH" ] || [ -z "$ZIP_PATH" ]; then
    usage >&2
    exit 2
fi
if [ "$SKIP_TAP_CHECK" -ne 1 ] && [ -z "$TAP_ROOT" ]; then
    err "--tap-root or VOICEBAR_HOMEBREW_TAP_ROOT is required unless --skip-tap-check is used"
    exit 2
fi

require_dir "VoiceBar.app" "$APP_PATH"
require_file "VoiceBar.zip" "$ZIP_PATH"
require_file "repo package.json" "$PACKAGE_ROOT/package.json"
require_file "bundled package.json" "$APP_PATH/Contents/Resources/package.json"
require_file "app Info.plist" "$APP_PATH/Contents/Info.plist"
if [ "$SKIP_TAP_CHECK" -ne 1 ]; then
    require_file "Homebrew formula" "$TAP_ROOT/Formula/voicelayer.rb"
    require_file "Homebrew cask" "$TAP_ROOT/Casks/voicebar.rb"
fi

canonical_version="$(read_json_version "$PACKAGE_ROOT/package.json")"
bundled_version="$(read_json_version "$APP_PATH/Contents/Resources/package.json")"
plist_short_version="$(read_plist_string "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString")"
plist_build_version="$(read_plist_string "$APP_PATH/Contents/Info.plist" "CFBundleVersion")"

require_equal "release version input" "$VERSION" "$canonical_version"
require_equal "bundled Contents/Resources/package.json version" "$bundled_version" "$canonical_version"
require_equal "Info.plist CFBundleShortVersionString" "$plist_short_version" "$canonical_version"
require_equal "Info.plist CFBundleVersion" "$plist_build_version" "$canonical_version"
verify_mcp_version_source
verify_signature
verify_stapled_ticket
verify_no_security_xattrs

if [ "$SKIP_TAP_CHECK" -ne 1 ]; then
    formula_version="$(extract_formula_version "$TAP_ROOT/Formula/voicelayer.rb")"
    cask_version="$(extract_cask_version "$TAP_ROOT/Casks/voicebar.rb")"
    require_equal "Formula/voicelayer.rb version" "$formula_version" "$canonical_version"
    require_equal "Casks/voicebar.rb version" "$cask_version" "$canonical_version"
    require_equal "Homebrew formula/cask version alignment" "$formula_version" "$cask_version"
fi

printf '[verify-voicebar-release] PASS: VoiceBar %s release artifact matches canonical package version and Developer ID/notary guards\n' "$canonical_version"
