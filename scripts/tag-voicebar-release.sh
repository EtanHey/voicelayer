#!/usr/bin/env bash
# The only way to create a VoiceLayer release tag (docs/voicebar-release-runbook.md).
#
# publish.yml's release gate binds every tag whose tree contains it. A `v*` tag on a tree
# without the gate is not stopped by that workflow, because a tag-triggered workflow is read
# from the tagged commit. This script guards against that honest mistake: it creates the tag
# locally only when HEAD carries the gate and its committed proof passes that same gate.
# It NEVER pushes. Pushing the tag publishes to npm; that stays a separate, deliberate step.
#
# Usage: scripts/tag-voicebar-release.sh <version>      e.g. 2.4.0
set -euo pipefail

refuse() { echo "[tag-voicebar-release] REFUSED: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || refuse "usage: scripts/tag-voicebar-release.sh <version>"
version="$1"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]] \
  || refuse "'$version' is not MAJOR.MINOR.PATCH[-pre] (no leading v, no leading zeros)"
tag="v$version"
bun="${BUN:-bun}"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a git checkout"
cd "$root"

[ -z "$(git status --porcelain --untracked-files=all)" ] \
  || refuse "the working tree is not clean; commit or remove every change first"

git cat-file -e HEAD:scripts/t3-optf5-proof.ts 2>/dev/null \
  && git show HEAD:scripts/t3-optf5-proof.ts | grep -F 'function releaseGate(' >/dev/null \
  || refuse "HEAD's tree has no release gate (scripts/t3-optf5-proof.ts release-gate)"
git show HEAD:.github/workflows/publish.yml 2>/dev/null | grep -F 't3-optf5-proof.ts release-gate --tag' >/dev/null \
  || refuse "HEAD's .github/workflows/publish.yml has no release gate step"

head_version="$(git show HEAD:package.json | "$bun" -e 'console.log(JSON.parse(await Bun.stdin.text()).version)')"
[ "$head_version" = "$version" ] || refuse "package.json at HEAD is '$head_version', not $version"

git cat-file -e "HEAD:release-proofs/$tag.json" 2>/dev/null \
  || refuse "release-proofs/$tag.json is not committed at HEAD (t3-optf5-proof.ts record, then commit it)"

# The same gate function publish.yml runs, with HEAD as the tag-to-be.
gate_out="$("$bun" scripts/t3-optf5-proof.ts release-gate --tag "$tag" --repo "$root" --before-tag HEAD)" \
  || refuse "the release gate refused HEAD (its reason is the line above)"
case "$gate_out" in
  *"PASS: release gate $tag"*) ;;
  *) refuse "the release gate did not pass $tag: $gate_out" ;;
esac

git tag -a "$tag" -m "VoiceLayer $tag" HEAD
# Confirm with the exact command the workflow runs; never leave a tag the workflow would refuse.
if ! "$bun" scripts/t3-optf5-proof.ts release-gate --tag "$tag" --repo "$root" >/dev/null; then
  git tag -d "$tag" >/dev/null
  refuse "the workflow's form of the gate refused the new tag; it was deleted"
fi

echo "[tag-voicebar-release] created annotated tag $tag at $(git rev-parse HEAD) (local only, NOT pushed)"
echo "[tag-voicebar-release] pushing it publishes to npm; when you mean to, run:"
echo "  git push origin $tag"
