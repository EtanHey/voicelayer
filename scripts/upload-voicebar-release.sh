#!/usr/bin/env bash
# Upload a verified VoiceBar.zip to the GitHub release, gated on the T3 Option+F5 proof.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=""
APP_PATH=""
ZIP_PATH=""
T3_PROOF=""

usage() {
    cat <<'EOF'
Usage: scripts/upload-voicebar-release.sh --version VERSION --app PATH --zip PATH --t3-proof PROOF.json

Uploading the release asset is publication (T3GATE1). This runs
scripts/verify-voicebar-release.sh with the installed-candidate T3 Option+F5
proof, which also binds the ZIP to the proven app, and only then runs
gh release upload vVERSION VoiceBar.zip --clobber. There is no bypass.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--app|--zip|--t3-proof)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: $1 requires a value" >&2
                exit 2
            fi
            case "$1" in
                --version) VERSION="$2" ;;
                --app) APP_PATH="$2" ;;
                --zip) ZIP_PATH="$2" ;;
                --t3-proof) T3_PROOF="$2" ;;
            esac
            shift 2
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

if [ -z "$VERSION" ] || [ -z "$APP_PATH" ] || [ -z "$ZIP_PATH" ]; then
    usage >&2
    exit 2
fi
if [ -z "$T3_PROOF" ]; then
    echo "[upload-voicebar-release] REFUSED: T3 Option+F5 proof is required before uploading (--t3-proof PROOF.json). There is no bypass." >&2
    exit 1
fi

"$PACKAGE_ROOT/scripts/verify-voicebar-release.sh" \
    --version "$VERSION" \
    --app "$APP_PATH" \
    --zip "$ZIP_PATH" \
    --skip-tap-check \
    --t3-proof "$T3_PROOF"

gh release upload "v$VERSION" "$ZIP_PATH" --clobber --repo EtanHey/voicelayer
