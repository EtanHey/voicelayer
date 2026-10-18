#!/usr/bin/env bash
# Promote a VoiceBar release to users: the only sanctioned delivery path (T3GATE1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=""
APP_PATH=""
ZIP_PATH=""
TAP_ROOT="${VOICEBAR_HOMEBREW_TAP_ROOT:-}"
T3_PROOF=""
FORMULA_SHA256=""
REPO="EtanHey/voicelayer"

usage() {
    cat <<'EOF'
Usage: scripts/promote-voicebar-release.sh --version VERSION --app PATH --zip PATH \
         --tap-root DIR --formula-sha256 SHA --t3-proof PROOF.json

Delivers a verified VoiceBar build to users, refusing at the first failed step:
  1. verify the artifact against the installed-candidate T3 Option+F5 proof
     (the proof's bundle digest must be this app's, and the ZIP must be this app);
  2. gh release upload vVERSION VoiceBar.zip --clobber, then download the published
     asset and require it to be byte-identical to the verified ZIP;
  3. bump Formula/voicelayer.rb (npm tarball url + --formula-sha256, the sha256 of the
     PUBLISHED voicelayer-mcp-VERSION.tgz) and Casks/voicebar.rb (version + ZIP sha256);
  4. rerun the tap-check verification with the proof;
  5. commit both files together and push the tap.

The tap must be clean. Do not write to the tap by hand. There is no bypass.
EOF
}

die() {
    printf '[promote-voicebar-release] REFUSED: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--app|--zip|--tap-root|--t3-proof|--formula-sha256)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: $1 requires a value" >&2
                exit 2
            fi
            case "$1" in
                --version) VERSION="$2" ;;
                --app) APP_PATH="$2" ;;
                --zip) ZIP_PATH="$2" ;;
                --tap-root) TAP_ROOT="$2" ;;
                --t3-proof) T3_PROOF="$2" ;;
                --formula-sha256) FORMULA_SHA256="$2" ;;
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

if [ -z "$VERSION" ] || [ -z "$APP_PATH" ] || [ -z "$ZIP_PATH" ] || [ -z "$TAP_ROOT" ]; then
    usage >&2
    exit 2
fi
[ -n "$T3_PROOF" ] || die "T3 Option+F5 proof is required before delivery (--t3-proof PROOF.json). There is no bypass."
[[ "$FORMULA_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "--formula-sha256 must be the sha256 of the published voicelayer-mcp-$VERSION.tgz"

FORMULA="$TAP_ROOT/Formula/voicelayer.rb"
CASK="$TAP_ROOT/Casks/voicebar.rb"
[ -f "$FORMULA" ] && [ -f "$CASK" ] || die "tap at $TAP_ROOT has no Formula/voicelayer.rb or Casks/voicebar.rb"
if [ -n "$(git -C "$TAP_ROOT" status --porcelain)" ]; then
    die "the tap at $TAP_ROOT has uncommitted changes; only this script writes the tap"
fi

# 1. Proof against the artifact being promoted (also binds the ZIP to the app).
"$PACKAGE_ROOT/scripts/verify-voicebar-release.sh" \
    --version "$VERSION" --app "$APP_PATH" --zip "$ZIP_PATH" --skip-tap-check --t3-proof "$T3_PROOF"

# 2. Publish the asset, then check what was actually published.
ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
gh release upload "v$VERSION" "$ZIP_PATH" --clobber --repo "$REPO"
PUBLISHED_SHA256="$(gh release download "v$VERSION" --pattern VoiceBar.zip --output - --repo "$REPO" | shasum -a 256 | awk '{print $1}')"
[ "$PUBLISHED_SHA256" = "$ZIP_SHA256" ] \
    || die "the published VoiceBar.zip ($PUBLISHED_SHA256) is not the verified ZIP ($ZIP_SHA256); the tap was not touched"

# 3. Bump formula and cask. The formula's first sha256 is the npm tarball's.
awk -v version="$VERSION" -v sha="$FORMULA_SHA256" '
    /^[[:space:]]*url "https:\/\/registry\.npmjs\.org\/voicelayer-mcp\/-\/voicelayer-mcp-/ {
        sub(/voicelayer-mcp-[^\/"]+\.tgz/, "voicelayer-mcp-" version ".tgz"); url = 1
    }
    url && !done && /^[[:space:]]*sha256 "/ { sub(/"[0-9a-f]*"/, "\"" sha "\""); done = 1 }
    { print }
' "$FORMULA" > "$FORMULA.promote" && mv "$FORMULA.promote" "$FORMULA"
awk -v version="$VERSION" -v sha="$ZIP_SHA256" '
    !v && /^[[:space:]]*version "/ { sub(/"[^"]*"/, "\"" version "\""); v = 1 }
    !s && /^[[:space:]]*sha256 "/ { sub(/"[^"]*"/, "\"" sha "\""); s = 1 }
    { print }
' "$CASK" > "$CASK.promote" && mv "$CASK.promote" "$CASK"
grep -F "sha256 \"$FORMULA_SHA256\"" "$FORMULA" >/dev/null || die "could not update the formula sha256"

# 4. Tap-check verification with the proof (cask sha256 must be the ZIP's).
if ! "$PACKAGE_ROOT/scripts/verify-voicebar-release.sh" \
    --version "$VERSION" --app "$APP_PATH" --zip "$ZIP_PATH" --tap-root "$TAP_ROOT" --t3-proof "$T3_PROOF"; then
    git -C "$TAP_ROOT" checkout -- Formula/voicelayer.rb Casks/voicebar.rb
    die "tap-check verification failed; tap edits reverted, nothing committed"
fi

# 5. Commit both together and push.
git -C "$TAP_ROOT" add Formula/voicelayer.rb Casks/voicebar.rb
git -C "$TAP_ROOT" commit -q -m "Update VoiceLayer formula and VoiceBar cask to $VERSION"
git -C "$TAP_ROOT" push -q origin HEAD
printf '[promote-voicebar-release] PASS: VoiceBar %s promoted (asset %s, tap pushed)\n' "$VERSION" "$ZIP_SHA256"
