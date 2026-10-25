#!/usr/bin/env bash
# Release the current VERSION: checks that the work is committed and pushed,
# builds and tests everything (scripts/build-all.sh), then tags v<VERSION>
# and pushes the tag. CI (.github/workflows/ci.yml) builds and tests it again
# and publishes the GitHub release with dist/.
#   scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "release: $*" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < VERSION)"
tag="v$VERSION"
[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes; commit them first"
git fetch --quiet --tags origin
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "$tag exists already: bump VERSION first"
branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$branch" 2>/dev/null)" ]] \
    || fail "$branch is not pushed (git push)"
scripts/build-all.sh
git tag -a "$tag" -m "BeeNote $VERSION"
git push origin "$tag"
echo "Tagged $tag; CI publishes the release: https://github.com/bartbeecoders/beenote/releases"
