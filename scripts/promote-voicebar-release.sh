#!/usr/bin/env bash
# Promote a VoiceBar release to users: the only sanctioned delivery path (T3GATE1).
set -euo pipefail

UPDATE_GATE_ARGS=("$@")
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
  2. upload VoiceBar.zip only when absent; require the published ZIP and npm tarball
     checksums to match before writing the tap (existing assets are never replaced);
  3. bump Formula/voicelayer.rb (npm tarball url + --formula-sha256, the sha256 of the
     PUBLISHED voicelayer-mcp-VERSION.tgz) and Casks/voicebar.rb (version + ZIP sha256);
  4. rerun the tap-check verification with the proof;
  5. commit both files together and push the tap default branch; on retry, reuse
     only the identical pending release commit. An already-pushed release is a no-op.

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

source "$SCRIPT_DIR/lib/update-gate.sh"
vl_update_gate "$PACKAGE_ROOT" bash "$SCRIPT_DIR/promote-voicebar-release.sh" ${UPDATE_GATE_ARGS[@]+"${UPDATE_GATE_ARGS[@]}"}

FORMULA="$TAP_ROOT/Formula/voicelayer.rb"
CASK="$TAP_ROOT/Casks/voicebar.rb"
[ -f "$FORMULA" ] && [ -f "$CASK" ] || die "tap at $TAP_ROOT has no Formula/voicelayer.rb or Casks/voicebar.rb"
if [ -n "$(git -C "$TAP_ROOT" status --porcelain)" ]; then
    die "the tap at $TAP_ROOT has uncommitted changes; only this script writes the tap"
fi

# 1. Proof against the artifact being promoted (also binds the ZIP to the app).
"$PACKAGE_ROOT/scripts/verify-voicebar-release.sh" \
    --version "$VERSION" --app "$APP_PATH" --zip "$ZIP_PATH" --skip-tap-check --t3-proof "$T3_PROOF"

# The tap must be on origin's default branch, with no unrelated unpublished commits.
DEFAULT_REF="$(git -C "$TAP_ROOT" ls-remote --symref origin HEAD | awk '$1 == "ref:" && $3 == "HEAD" {print $2}')"
[[ "$DEFAULT_REF" == refs/heads/* ]] || die "cannot determine the tap origin default branch"
[ "$(git -C "$TAP_ROOT" symbolic-ref -q HEAD)" = "$DEFAULT_REF" ] || die "tap must be on $DEFAULT_REF"
git -C "$TAP_ROOT" fetch -q origin "$DEFAULT_REF"
REMOTE_HEAD="$(git -C "$TAP_ROOT" rev-parse FETCH_HEAD)"
git -C "$TAP_ROOT" merge-base --is-ancestor "$REMOTE_HEAD" HEAD || die "tap diverged from origin; reconcile it before retrying"
AHEAD="$(git -C "$TAP_ROOT" rev-list --count "$REMOTE_HEAD..HEAD")"
MESSAGE="Update VoiceLayer formula and VoiceBar cask to $VERSION"
if [ "$AHEAD" != 0 ]; then
    [ "$AHEAD" = 1 ] && [ "$(git -C "$TAP_ROOT" log -1 --format=%s)" = "$MESSAGE" ] \
        && [ "$(git -C "$TAP_ROOT" rev-list --count --merges "$REMOTE_HEAD..HEAD")" = 0 ] \
        || die "tap has unrelated unpushed commits; only this version's release commit may be retried"
    case "$(git -C "$TAP_ROOT" diff-tree --no-commit-id --name-only -r HEAD)" in
        Casks/voicebar.rb|Formula/voicelayer.rb|$'Casks/voicebar.rb\nFormula/voicelayer.rb') ;;
        *) die "pending tap release commit changes unrelated files" ;;
    esac
fi

# Prepare exactly the release delta on the remote tip, so an existing local commit must
# match BOTH the version/checksums and every other byte before we will push it.
PREPARED="$(mktemp -d)"
trap 'rm -rf "$PREPARED"' EXIT
git -C "$TAP_ROOT" show "$REMOTE_HEAD:Formula/voicelayer.rb" > "$PREPARED/formula-base"
git -C "$TAP_ROOT" show "$REMOTE_HEAD:Casks/voicebar.rb" > "$PREPARED/cask-base"
ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

# Prepare formula and cask. The formula's first sha256 is the npm tarball's.
awk -v version="$VERSION" -v sha="$FORMULA_SHA256" '
    /^[[:space:]]*url "https:\/\/registry\.npmjs\.org\/voicelayer-mcp\/-\/voicelayer-mcp-/ {
        sub(/voicelayer-mcp-[^\/"]+\.tgz/, "voicelayer-mcp-" version ".tgz"); url = 1
    }
    url && !done && /^[[:space:]]*sha256 "/ { sub(/"[0-9a-f]*"/, "\"" sha "\""); done = 1 }
    { print }
' "$PREPARED/formula-base" > "$PREPARED/formula"
awk -v version="$VERSION" -v sha="$ZIP_SHA256" '
    !v && /^[[:space:]]*version "/ { sub(/"[^"]*"/, "\"" version "\""); v = 1 }
    !s && /^[[:space:]]*sha256 "/ { sub(/"[^"]*"/, "\"" sha "\""); s = 1 }
    { print }
' "$PREPARED/cask-base" > "$PREPARED/cask"
grep -F "sha256 \"$FORMULA_SHA256\"" "$PREPARED/formula" >/dev/null || die "could not update the formula sha256"

if [ "$AHEAD" = 1 ]; then
    cmp -s "$PREPARED/formula" "$FORMULA" && cmp -s "$PREPARED/cask" "$CASK" \
        || die "pending tap release commit does not match this version and checksums"
fi

# Verify published bytes, including the npm tarball (not a local npm pack).
PUBLISHED_FORMULA_SHA256="$(curl -fsSL "https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-$VERSION.tgz" | shasum -a 256 | awk '{print $1}')"
[ "$PUBLISHED_FORMULA_SHA256" = "$FORMULA_SHA256" ] || die "published npm tarball checksum differs from --formula-sha256"
ASSETS="$(gh release view "v$VERSION" --json assets --jq '.assets[].name' --repo "$REPO")"
if ! printf '%s\n' "$ASSETS" | grep -Fx VoiceBar.zip >/dev/null; then
    # No --clobber: a concurrent upload must also never overwrite an existing asset.
    gh release upload "v$VERSION" "$ZIP_PATH" --repo "$REPO"
fi
PUBLISHED_SHA256="$(gh release download "v$VERSION" --pattern VoiceBar.zip --output - --repo "$REPO" | shasum -a 256 | awk '{print $1}')"
[ "$PUBLISHED_SHA256" = "$ZIP_SHA256" ] \
    || die "the published VoiceBar.zip ($PUBLISHED_SHA256) is not the verified ZIP ($ZIP_SHA256); the tap was not touched"
cp "$PREPARED/formula" "$FORMULA"
cp "$PREPARED/cask" "$CASK"

# 4. Tap-check verification with the proof (cask sha256 must be the ZIP's).
if ! "$PACKAGE_ROOT/scripts/verify-voicebar-release.sh" \
    --version "$VERSION" --app "$APP_PATH" --zip "$ZIP_PATH" --tap-root "$TAP_ROOT" --t3-proof "$T3_PROOF"; then
    git -C "$TAP_ROOT" checkout -- Formula/voicelayer.rb Casks/voicebar.rb
    die "tap-check verification failed; tap edits reverted, nothing committed"
fi

# 5. Commit both together and push.
git -C "$TAP_ROOT" add Formula/voicelayer.rb Casks/voicebar.rb
if ! git -C "$TAP_ROOT" diff --cached --quiet; then
    git -C "$TAP_ROOT" commit -q -m "$MESSAGE"
fi
PROMOTION_HEAD="$(git -C "$TAP_ROOT" rev-parse HEAD)"
git -C "$TAP_ROOT" push -q origin "$PROMOTION_HEAD:$DEFAULT_REF"
printf '[promote-voicebar-release] PASS: VoiceBar %s promoted (asset %s, tap pushed)\n' "$VERSION" "$ZIP_SHA256"
