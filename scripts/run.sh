#!/usr/bin/env bash
# Start the latest BeeNote: rebuild whenever the sources differ from those of
# the last build (src/, VERSION or scripts/build.sh, by content), then run it.
#   scripts/run.sh [file]
set -euo pipefail
cd "$(dirname "$0")/.."

stamp=$( (find src -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; sha256sum VERSION scripts/build.sh) | sha256sum | cut -d' ' -f1)
if [[ ! -x build/beenote ]] || [[ "$(cat build/.run-stamp 2>/dev/null)" != "$stamp" ]]; then
    scripts/build.sh
    echo "$stamp" > build/.run-stamp
fi
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "BeeNote needs a Wayland session (WAYLAND_DISPLAY is not set)." >&2
    exit 1
fi
exec ./build/beenote "$@"
