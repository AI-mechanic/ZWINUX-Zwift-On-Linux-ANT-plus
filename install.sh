#!/usr/bin/env bash
# One-time setup: make the Zwift icon start Zwift through zwift.sh, and set
# up ANT+ support.
#
#   ./install.sh            the Wine prefix with Zwift in it is ./prefix
#   ./install.sh PREFIX     it is at PREFIX; ./prefix becomes a link to it
#
# Running it again is harmless: it only fixes what is not set up yet.

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DESKTOP="$HOME/.local/share/applications/zwift.desktop"
export WINE_ROOT="${WINE_ROOT:-/opt/wine-staging}"

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "Wine prefix"
if [ -n "${1:-}" ]; then
  target="$(readlink -f "$1")"
  [ -d "$target/drive_c" ] || die "no Wine prefix at $1"
  if [ -L "$HERE/prefix" ] || [ ! -e "$HERE/prefix" ]; then
    ln -sfn "$target" "$HERE/prefix"
    echo "$HERE/prefix now points to $target"
  elif [ "$(readlink -f "$HERE/prefix")" != "$target" ]; then
    die "$HERE/prefix is a different prefix; move it away first"
  fi
fi
export WINEPREFIX="$HERE/prefix"
[ -d "$WINEPREFIX/drive_c" ] || die "no Wine prefix at $WINEPREFIX: give its path, ./install.sh PREFIX"
ZDIR="$WINEPREFIX/drive_c/Program Files (x86)/Zwift"
[ -f "$ZDIR/ZwiftLauncher.exe" ] || die "Zwift is not installed in $WINEPREFIX"
[ -f "$ZDIR/RunFromProcess-x64.exe" ] ||
  die "RunFromProcess-x64.exe is missing from $ZDIR, and zwift.sh needs it to start the game"
[ -x "$WINE_ROOT/bin/wine" ] || die "no Wine in $WINE_ROOT (set WINE_ROOT if it is somewhere else)"
echo "Zwift is in $WINEPREFIX"
chmod +x "$HERE/zwift.sh" "$HERE/zwift-ant.sh" "$HERE/zwift-fetch.py"

say "The Zwift icon"
exec_line="\"$HERE/zwift.sh\""     # quoted, in case the path has a space
# a Wine other than the default has to be remembered for the icon
[ "$WINE_ROOT" = /opt/wine-staging ] || exec_line="env WINE_ROOT=$WINE_ROOT $exec_line"
if [ -f "$DESKTOP" ]; then
  sed -i "s|^Exec=.*|Exec=$exec_line|" "$DESKTOP"
else
  mkdir -p "$(dirname "$DESKTOP")"
  printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Zwift' \
    "Exec=$exec_line" 'Icon=applications-games' 'Terminal=false' \
    'Categories=Game;' 'StartupWMClass=zwiftapp.exe' >"$DESKTOP"
fi
if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$(dirname "$DESKTOP")" 2>/dev/null || true
fi
echo "the Zwift icon starts $exec_line"

say "ANT+"
if ! bash "$HERE/zwift-ant.sh" setup; then
  echo
  echo "ANT+ is not set up; see above. Zwift starts without it. Once that is"
  echo "fixed, run: $HERE/zwift-ant.sh setup"
fi

say "Done"
echo "Start Zwift from the app grid. README.md says what is where."
