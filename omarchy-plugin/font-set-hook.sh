#!/usr/bin/env bash
# Omarchy font-set hook (installed by BeeNote's scripts/deploy-omarchy.sh):
# keep BeeNote's font in step with `omarchy font set`. A running BeeNote
# notices the changed configuration within a second.
conf="$HOME/.config/beenote/beenote.conf"
family=$(omarchy-font-current 2>/dev/null) || exit 0
file=$(fc-match -f '%{file}' "$family:style=Regular" 2>/dev/null) || exit 0
[[ $file == *.ttf ]] || exit 0                  # BeeNote reads TrueType (.ttf) fonts
mkdir -p "$(dirname "$conf")"
touch "$conf"
if grep -q '^font *=' "$conf"; then
  sed -i "s|^font *=.*|font = $file|" "$conf"
else
  printf 'font = %s\n' "$file" >> "$conf"
fi
