#!/usr/bin/env bash
# Render the icon: src/icon/beenote.svg (and beenote-small.svg, the same
# with less detail, for 32 px and under) to the PNGs that plat_win.s puts
# in beenote.exe's resources, and copy beenote.svg to the Omarchy plugin
# (the launcher's icon on Linux). Needs rsvg-convert, oxipng (optional).
#   tools/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/../src/icon"
for s in 16 20 24 32 40 48 64 256; do
    svg=beenote.svg
    (( s <= 32 )) && svg=beenote-small.svg
    rsvg-convert -w "$s" -h "$s" "$svg" -o "beenote-$s.png"
done
command -v oxipng >/dev/null && oxipng -q -o 4 --strip all beenote-*.png
cp beenote.svg ../../omarchy-plugin/beenote.svg
ls -l beenote-*.png
