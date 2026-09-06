#!/bin/bash
# Publishes the notarized DMG as a GitHub release.
#
#   bash Tools/Release/publish.sh <notes.md>
#
# Refuses anything that is not stapled: an unnotarized image would greet every
# download with a Gatekeeper block. Creates the v<version> tag on HEAD when it
# does not exist yet, then creates the release with the DMG as its one asset.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NOTES_PATH="${1:?usage: publish.sh <release-notes.md>}"

fail() {
    printf 'publish: %s\n' "$*" >&2
    exit 1
}

command -v gh >/dev/null 2>&1 || fail "gh is not installed"
[[ -f "$NOTES_PATH" ]] || fail "release notes not found at $NOTES_PATH"

VERSION="$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' "$ROOT_DIR/project.yml")"
[[ -n "$VERSION" ]] || fail "MARKETING_VERSION missing from project.yml"
DMG_PATH="$ROOT_DIR/dist/dockit-$VERSION.dmg"
TAG="v$VERSION"

[[ -f "$DMG_PATH" ]] || fail "no DMG at $DMG_PATH; run release.sh all first"
xcrun stapler validate "$DMG_PATH" >/dev/null || fail "$DMG_PATH is not stapled; nothing was published"
/usr/sbin/spctl --assess --type open --context context:primary-signature "$DMG_PATH" || fail "Gatekeeper rejects $DMG_PATH"

cd "$ROOT_DIR"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    printf 'tag %s already exists\n' "$TAG"
else
    git tag -a "$TAG" -m "dockit $VERSION"
    git push origin "$TAG"
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    fail "release $TAG already exists; delete it or bump the version"
fi
gh release create "$TAG" "$DMG_PATH" --title "dockit $VERSION" --notes-file "$NOTES_PATH"
gh release view "$TAG" --json url -q .url
