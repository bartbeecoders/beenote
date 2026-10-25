#!/usr/bin/env bash
# Focus an existing BeeNote window, or start one.
# Match the Wayland class (app_id "beenote") exactly: a title search would
# also hit other windows whose title happens to contain the word.
set -euo pipefail

binary=${1:-"$HOME/.local/bin/beenote"}
shift || true

address=$(hyprctl clients -j | jq -r 'first(.[] | select(.class == "beenote") | .address) // empty')
if [[ -n $address ]]; then
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })" >/dev/null 2>&1 \
    || hyprctl dispatch focuswindow "address:$address"
  exit 0
fi

exec setsid uwsm-app -- "$binary" "$@"
