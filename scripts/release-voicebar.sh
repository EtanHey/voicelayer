#!/usr/bin/env bash
# Build a notarized VoiceBar.zip release artifact for the Homebrew cask.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=""
UPLOAD=0
NOTARY_PROFILE="${VOICEBAR_NOTARY_PROFILE:-notary-layers}"
ENTITLEMENTS_PLIST="${VOICEBAR_ENTITLEMENTS:-$PACKAGE_ROOT/flow-bar/bundle/VoiceBar.entitlements}"
ARTIFACT_ROOT="${VOICEBAR_RELEASE_ROOT:-$PACKAGE_ROOT/dist/voicebar-release}"

usage() {
    cat <<'EOF'
Usage: scripts/release-voicebar.sh [--version VERSION] [--output-dir DIR] [--notary-profile PROFILE] [--upload]

Builds an isolated Developer-ID-signed, notarized VoiceBar.zip for the GitHub
release and prints the EtanHey/homebrew-layers Casks/voicebar.rb bump inputs.

Options:
  --version VERSION        Release version. Defaults to package.json version.
  --output-dir DIR         Artifact root. Defaults to dist/voicebar-release.
  --notary-profile NAME    notarytool keychain profile. Defaults to notary-layers.
  --upload                 Run gh release upload vVERSION VoiceBar.zip --clobber.
EOF
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

if [[ -z "$VERSION" ]]; then
    VERSION="$(cd "$PACKAGE_ROOT" && bun -e 'console.log(JSON.parse(await Bun.file("package.json").text()).version)')"
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

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

echo "[release-voicebar] Artifact: $ZIP_PATH"
echo "[release-voicebar] sha256: $SHA256"
echo "[release-voicebar] Upload command:"
echo "  gh release upload v$VERSION \"$ZIP_PATH\" --clobber --repo EtanHey/voicelayer"
echo "[release-voicebar] Homebrew cask bump:"
echo "  repo: EtanHey/homebrew-layers"
echo "  file: Casks/voicebar.rb"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA256\""

if [[ "$UPLOAD" -eq 1 ]]; then
    gh release upload "v$VERSION" "$ZIP_PATH" --clobber --repo EtanHey/voicelayer
fi
