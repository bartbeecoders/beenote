#!/usr/bin/env bash
# Build BeeNote and add it to Omarchy. Re-run it to update; a running
# BeeNote keeps its old binary until it is restarted. It installs:
#   ~/.local/bin/beenote
#   a launcher entry (Super + Space) and icon; text files can open in it
#   ~/.config/beenote/beenote.conf with the Omarchy font, and a font-set
#     hook that keeps it in step with `omarchy font set`
#   the bar plugin bart.beenote, enabled on the right
# The colours need nothing: BeeNote reads the current Omarchy theme itself.
#
#   scripts/deploy-omarchy.sh              install / update
#   scripts/deploy-omarchy.sh --no-plugin  everything but the bar button
#   scripts/deploy-omarchy.sh --uninstall  remove what this script installed
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
plugin=1
uninstall=0
while (($#)); do
  case $1 in
    --no-plugin) plugin=0; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "deploy-omarchy: unknown option $1 (see --help)" >&2; exit 1 ;;
  esac
done

plugin_id=bart.beenote
bin_dir=$HOME/.local/bin
share=$HOME/.local/share/beenote
plugins_dir=$HOME/.config/omarchy/plugins
link=$plugins_dir/$plugin_id
apps=$HOME/.local/share/applications
icons=$HOME/.local/share/icons/hicolor/scalable/apps
conf=$HOME/.config/beenote/beenote.conf
hook=$HOME/.config/omarchy/hooks/font-set.d/beenote

fail() {
  echo "deploy-omarchy: $*" >&2
  exit 1
}

refresh_caches() {
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$apps" || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
}

if ((uninstall)); then
  if [[ -L $link ]]; then
    omarchy plugin disable "$plugin_id" >/dev/null 2>&1 || true
    rm -f "$link"
  fi
  rm -rf "$share"
  rm -f "$bin_dir/beenote" "$apps/beenote.desktop" "$icons/beenote.svg" "$hook"
  refresh_caches
  echo "BeeNote removed. (Its settings stay in $conf.)"
  exit 0
fi

for tool in as ld jq fc-match omarchy omarchy-shell; do
  command -v $tool >/dev/null || fail "$tool is not on PATH"
done

# --- build -------------------------------------------------------------------
echo "==> Building"
"$repo/scripts/build.sh" release
"$repo/build/beenote" --version >/dev/null || fail "the new binary does not run"
version=$("$repo/build/beenote" --version)

# --- install -----------------------------------------------------------------
echo "==> Installing $bin_dir/beenote"
mkdir -p "$bin_dir"
cp "$repo/build/beenote" "$bin_dir/beenote.new"   # replaced atomically: a running
chmod 755 "$bin_dir/beenote.new"                    # copy keeps working
mv -f "$bin_dir/beenote.new" "$bin_dir/beenote"

echo "==> Installing the launcher entry and icon"
mkdir -p "$apps" "$icons"
sed "s|@BIN@|$bin_dir/beenote|" "$repo/omarchy-plugin/beenote.desktop" > "$apps/beenote.desktop"
cp "$repo/omarchy-plugin/beenote.svg" "$icons/beenote.svg"
refresh_caches

echo "==> Setting the Omarchy font ($(omarchy-font-current 2>/dev/null || echo '?'))"
mkdir -p "$(dirname "$conf")" "$(dirname "$hook")"
if [[ ! -f $conf ]]; then
  cat > "$conf" <<CONF
# BeeNote settings. A running BeeNote applies changes within a second.
# font: a TrueType (.ttf) file; the Omarchy font-set hook keeps it current.
# size: in points, as Omarchy's font sizes (12 = 16 px).
font =
size = 12
CONF
fi
install -m 755 "$repo/omarchy-plugin/font-set-hook.sh" "$hook"
"$hook"                                             # (the current font, now)
grep '^font' "$conf" | sed 's/^/    /'

if ((plugin)); then
  # The plugin is copied out of the repository, so the bar button always
  # matches the installed binary.
  echo "==> Installing the bar plugin to $share/omarchy-plugin"
  omarchy plugin validate "$repo/omarchy-plugin"
  mkdir -p "$share"
  rm -rf "$share/omarchy-plugin.new"
  cp -r "$repo/omarchy-plugin" "$share/omarchy-plugin.new"
  jq --arg v "$(tr -d '[:space:]' < "$repo/VERSION")" '.version = $v' \
    "$repo/omarchy-plugin/manifest.json" > "$share/omarchy-plugin.new/manifest.json"
  rm -rf "$share/omarchy-plugin"
  mv "$share/omarchy-plugin.new" "$share/omarchy-plugin"

  echo "==> Linking $link"
  mkdir -p "$plugins_dir"
  if [[ -L $link ]]; then
    [[ $(readlink -f "$link") == "$(readlink -f "$share/omarchy-plugin")" ]] \
      || fail "$link points at $(readlink -f "$link"), not $share/omarchy-plugin"
  elif [[ -e $link ]]; then
    fail "$link exists and is not a symlink"
  else
    ln -s "$share/omarchy-plugin" "$link"
  fi

  echo "==> Enabling $plugin_id"
  # rescanPlugins can take longer than the default 2 s IPC budget.
  export OMARCHY_SHELL_IPC_TIMEOUT="${OMARCHY_SHELL_IPC_TIMEOUT:-15s}"
  omarchy-shell shell rescanPlugins >/dev/null \
    || fail "the shell did not rescan. When it is running: omarchy plugin enable $plugin_id --section right"
  plugin_list=""
  read_plugin_list() {
    plugin_list=$(omarchy plugin list --json) || fail "the shell did not answer. Run: omarchy restart shell"
  }
  deadline=$((SECONDS + 20))
  until read_plugin_list; jq -e --arg id "$plugin_id" 'any(.[]; .id == $id)' <<<"$plugin_list" >/dev/null; do
    ((SECONDS < deadline)) || fail "plugin '$plugin_id' is not known. Run: omarchy-shell shell rescanPlugins"
    sleep 0.2
  done
  if jq -e --arg id "$plugin_id" 'any(.[]; .id == $id and .enabled)' <<<"$plugin_list" >/dev/null; then
    echo "Already enabled"
  else
    omarchy plugin enable "$plugin_id" --section right
  fi
fi

echo
echo "$version is installed."
echo "  Binary    $bin_dir/beenote"
echo "  Launcher  BeeNote (Super + Space); text files can open in it"
echo "  Theme     follows the Omarchy theme live"
echo "  Font      $conf (follows omarchy font set)"
if ((plugin)); then
  echo "  Bar       a click focuses BeeNote, or starts it"
  echo "  Command   omarchy-shell $plugin_id app"
  echo
  echo "A key can do the same, in ~/.config/hypr/bindings.lua:"
  echo "  o.bind(\"SUPER + ALT + N\", \"BeeNote\", \"omarchy-shell $plugin_id app\")"
fi
