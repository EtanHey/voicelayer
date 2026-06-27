#!/usr/bin/env bash
# Build a notarized VoiceBar.zip release artifact for the Homebrew cask.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=""
UPLOAD=0
SKIP_TAP_CHECK=0
NOTARY_PROFILE="${VOICEBAR_NOTARY_PROFILE:-notary-layers}"
ENTITLEMENTS_PLIST="${VOICEBAR_ENTITLEMENTS:-$PACKAGE_ROOT/flow-bar/bundle/VoiceBar.entitlements}"
ARTIFACT_ROOT="${VOICEBAR_RELEASE_ROOT:-$PACKAGE_ROOT/dist/voicebar-release}"
TAP_ROOT="${VOICEBAR_HOMEBREW_TAP_ROOT:-}"

usage() {
    cat <<'EOF'
Usage: scripts/release-voicebar.sh [--version VERSION] [--output-dir DIR] [--notary-profile PROFILE] [--tap-root DIR] [--skip-tap-check] [--upload]

Builds an isolated Developer-ID-signed, notarized VoiceBar.zip for the GitHub
release and prints the EtanHey/homebrew-layers formula and cask bump inputs.

Options:
  --version VERSION        Release version. Defaults to package.json version.
  --output-dir DIR         Artifact root. Defaults to dist/voicebar-release.
  --notary-profile NAME    notarytool keychain profile. Defaults to notary-layers.
  --tap-root DIR           Homebrew tap checkout. Required unless --skip-tap-check is used.
  --skip-tap-check         Verify artifact only. Use before the matching tap bump exists.
  --upload                 Run gh release upload vVERSION VoiceBar.zip --clobber.
EOF
}

canonical_version() {
    (cd "$PACKAGE_ROOT" && bun -e 'console.log(JSON.parse(await Bun.file("package.json").text()).version)')
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --version requires a value" >&2
                exit 2
            fi
            VERSION="$2"
            shift 2
            ;;
        --output-dir)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --output-dir requires a value" >&2
                exit 2
            fi
            ARTIFACT_ROOT="$2"
            shift 2
            ;;
        --notary-profile)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --notary-profile requires a value" >&2
                exit 2
            fi
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --tap-root)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --tap-root requires a value" >&2
                exit 2
            fi
            TAP_ROOT="$2"
            shift 2
            ;;
        --skip-tap-check)
            SKIP_TAP_CHECK=1
            shift
            ;;
        --upload)
            UPLOAD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

CANONICAL_VERSION="$(canonical_version)"
if [[ -z "$VERSION" ]]; then
    VERSION="$CANONICAL_VERSION"
elif [[ "$VERSION" != "$CANONICAL_VERSION" ]]; then
    echo "ERROR: --version $VERSION does not match package.json version $CANONICAL_VERSION" >&2
    exit 1
fi

if [[ "$SKIP_TAP_CHECK" -ne 1 && -z "$TAP_ROOT" ]]; then
    echo "ERROR: --tap-root or VOICEBAR_HOMEBREW_TAP_ROOT is required unless --skip-tap-check is used" >&2
    exit 2
fi

ARTIFACT_DIR="$ARTIFACT_ROOT/$VERSION"
APP_PATH="$ARTIFACT_DIR/VoiceBar.app"
ZIP_PATH="$ARTIFACT_DIR/VoiceBar.zip"

mkdir -p "$ARTIFACT_DIR"
rm -rf "$APP_PATH" "$ZIP_PATH"

echo "[release-voicebar] Building notarized VoiceBar $VERSION at $APP_PATH"
(
    cd "$PACKAGE_ROOT"
    VOICEBAR_SKIP_LAUNCHD_INSTALL=1 \
    VOICEBAR_ENTITLEMENTS="$ENTITLEMENTS_PLIST" \
    VOICEBAR_NOTARY_PROFILE="$NOTARY_PROFILE" \
    VOICEBAR_REQUIRE_NOTARIZATION=1 \
    VOICEBAR_RELEASE_ZIP="$ZIP_PATH" \
    bash flow-bar/build-app.sh \
        --install-path "$APP_PATH" \
        --no-stop \
        --no-relaunch
)

VERIFY_ARGS=(
    --version "$VERSION"
    --app "$APP_PATH"
    --zip "$ZIP_PATH"
)
if [[ -n "$TAP_ROOT" ]]; then
    VERIFY_ARGS+=(--tap-root "$TAP_ROOT")
fi
if [[ "$SKIP_TAP_CHECK" -eq 1 ]]; then
    VERIFY_ARGS+=(--skip-tap-check)
fi
"$PACKAGE_ROOT/scripts/verify-voicebar-release.sh" "${VERIFY_ARGS[@]}"

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

echo "[release-voicebar] Artifact: $ZIP_PATH"
echo "[release-voicebar] sha256: $SHA256"
echo "[release-voicebar] Upload command:"
echo "  gh release upload v$VERSION \"$ZIP_PATH\" --clobber --repo EtanHey/voicelayer"
echo "[release-voicebar] Homebrew formula and cask bump:"
echo "  repo: EtanHey/homebrew-layers"
echo "  files: Formula/voicelayer.rb Casks/voicebar.rb"
echo "  Formula/voicelayer.rb: update npm url to voicelayer-mcp-$VERSION.tgz and sha256 to the npm tarball checksum"
echo "  Casks/voicebar.rb: version \"$VERSION\""
echo "  Casks/voicebar.rb: sha256 \"$SHA256\""
if [[ "$SKIP_TAP_CHECK" -eq 1 && -n "$TAP_ROOT" ]]; then
    echo "  after updating the tap, rerun verification without --skip-tap-check:"
    echo "    \"$PACKAGE_ROOT/scripts/verify-voicebar-release.sh\" --version \"$VERSION\" --app \"$APP_PATH\" --zip \"$ZIP_PATH\" --tap-root \"$TAP_ROOT\""
fi
if [[ -n "$TAP_ROOT" ]]; then
    echo "  commit both formula and cask together:"
    echo "    git -C \"$TAP_ROOT\" add Formula/voicelayer.rb Casks/voicebar.rb"
    echo "    git -C \"$TAP_ROOT\" commit -m \"Update VoiceLayer formula and VoiceBar cask to $VERSION\""
fi

if [[ "$UPLOAD" -eq 1 ]]; then
    gh release upload "v$VERSION" "$ZIP_PATH" --clobber --repo EtanHey/voicelayer
fi
