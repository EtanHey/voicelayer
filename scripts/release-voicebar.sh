#!/usr/bin/env bash
# Build a notarized VoiceBar.zip release artifact for the Homebrew cask.
set -euo pipefail

UPDATE_GATE_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=""
SKIP_TAP_CHECK=0
NOTARY_PROFILE="${VOICEBAR_NOTARY_PROFILE:-notary-layers}"
ENTITLEMENTS_PLIST="${VOICEBAR_ENTITLEMENTS:-$PACKAGE_ROOT/flow-bar/bundle/VoiceBar.entitlements}"
ARTIFACT_ROOT="${VOICEBAR_RELEASE_ROOT:-$PACKAGE_ROOT/.build.noindex/voicebar-release}"
TAP_ROOT="${VOICEBAR_HOMEBREW_TAP_ROOT:-}"
T3_PROOF=""

usage() {
    cat <<'EOF'
Usage: scripts/release-voicebar.sh [--version VERSION] [--output-dir DIR] [--notary-profile PROFILE] [--tap-root DIR --t3-proof PROOF.json] [--skip-tap-check]

Builds an isolated Developer-ID-signed, notarized VoiceBar.zip for the GitHub
release and prints the EtanHey/homebrew-layers formula and cask bump inputs.

Options:
  --version VERSION        Release version. Defaults to package.json version.
  --output-dir DIR         Artifact root. Defaults to .build.noindex/voicebar-release.
  --notary-profile NAME    notarytool keychain profile. Defaults to notary-layers.
  --tap-root DIR           Homebrew tap checkout. Required unless --skip-tap-check is used.
  --t3-proof PROOF.json    Installed-candidate T3 Option+F5 PASS proof. Required by the
                           tap check, which gates the cask bump; there is no bypass.
  --skip-tap-check         Verify artifact only. Use before the matching tap bump exists.
                           A fresh build is newer than any proof, so a release build
                           always runs with this; the tap check runs after install.

Delivery (asset upload, formula and cask commit and push) is gated on the
installed-candidate T3 Option+F5 proof and lives only in
scripts/promote-voicebar-release.sh. This script always rebuilds, and a fresh
build is newer than any proof, so it cannot deliver.
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
        --t3-proof)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --t3-proof requires a value" >&2
                exit 2
            fi
            T3_PROOF="$2"
            shift 2
            ;;
        --skip-tap-check)
            SKIP_TAP_CHECK=1
            shift
            ;;
        --upload)
            echo "ERROR: --upload is retired. A fresh build can never carry a T3 Option+F5 proof." >&2
            echo "Install the candidate, produce the proof, then: scripts/promote-voicebar-release.sh --t3-proof PROOF.json (docs/voicebar-release-runbook.md)" >&2
            exit 2
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

source "$SCRIPT_DIR/lib/noindex-path.sh"
require_release_artifact_path "$ARTIFACT_ROOT"
ARTIFACT_DIR="$ARTIFACT_ROOT/$VERSION"
APP_PATH="$ARTIFACT_DIR/VoiceBar.app"
ZIP_PATH="$ARTIFACT_DIR/VoiceBar.zip"

# Resolve every final destination before cleanup, including existing child symlinks.
ARTIFACT_DIR="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$ARTIFACT_DIR")"
APP_PATH="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$APP_PATH")"
ZIP_PATH="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$ZIP_PATH")"
require_release_artifact_path "$ARTIFACT_DIR"
require_release_artifact_path "$APP_PATH" "$ARTIFACT_DIR"
require_release_artifact_path "$ZIP_PATH" "$ARTIFACT_DIR"

source "$SCRIPT_DIR/lib/update-gate.sh"
vl_update_gate "$PACKAGE_ROOT" bash "$SCRIPT_DIR/release-voicebar.sh" ${UPDATE_GATE_ARGS[@]+"${UPDATE_GATE_ARGS[@]}"}

mkdir -p "$ARTIFACT_DIR"
"$(release_artifact_python)" "$SCRIPT_DIR/lib/cleanup-release-artifacts.py" "$ARTIFACT_DIR" "$APP_PATH" "$ZIP_PATH"

echo "[release-voicebar] Building notarized VoiceBar $VERSION at $APP_PATH"
(
    cd "$PACKAGE_ROOT"
    VOICEBAR_QA_BUILD=0 \
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

# The notarized bundle must not carry the dev/CI-only QA probes (Etan ruling 2).
bash "$PACKAGE_ROOT/scripts/check-voicebar-qa-free.sh" "$APP_PATH/Contents/MacOS/VoiceBar"

VERIFY_ARGS=(
    --version "$VERSION"
    --app "$APP_PATH"
    --zip "$ZIP_PATH"
)
if [[ -n "$TAP_ROOT" ]]; then
    VERIFY_ARGS+=(--tap-root "$TAP_ROOT")
fi
if [[ -n "$T3_PROOF" ]]; then
    VERIFY_ARGS+=(--t3-proof "$T3_PROOF")
fi
if [[ "$SKIP_TAP_CHECK" -eq 1 ]]; then
    VERIFY_ARGS+=(--skip-tap-check)
fi
"$PACKAGE_ROOT/scripts/verify-voicebar-release.sh" "${VERIFY_ARGS[@]}"

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

echo "[release-voicebar] Artifact: $ZIP_PATH"
echo "[release-voicebar] sha256: $SHA256"
echo "[release-voicebar] Next: install this candidate, produce the T3 Option+F5 proof"
echo "  (docs/voicebar-release-runbook.md), then deliver it. Never write the tap by hand."
echo "[release-voicebar] Delivery (asset upload + EtanHey/homebrew-layers formula and cask commit/push):"
echo "  \"$PACKAGE_ROOT/scripts/promote-voicebar-release.sh\" --version \"$VERSION\" --app \"$APP_PATH\" --zip \"$ZIP_PATH\" \\"
echo "    --tap-root \"${TAP_ROOT:-TAP_ROOT}\" --formula-sha256 NPM_TGZ_SHA256 --t3-proof PROOF.json"
echo "  It writes Formula/voicelayer.rb (voicelayer-mcp-$VERSION.tgz + the published npm tarball sha256)"
echo "  and Casks/voicebar.rb (version \"$VERSION\", sha256 \"$SHA256\")."
if [[ "$SKIP_TAP_CHECK" -eq 1 ]]; then
    echo "  Artifact-only run: the tap check with --t3-proof PROOF.json runs inside promote-voicebar-release.sh."
fi
