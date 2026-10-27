#!/usr/bin/env bash
# ANT+ USB sticks for Zwift under Wine.
#
# Zwift reaches ANT+ sticks through libusb0.dll (libusb-win32), which needs
# a Windows driver that Wine does not have. This builds a Wine version of
# it, stanson-ch/libusb-wine with ant/libusb-wine-ant.patch, into ant/lib,
# where zwift.sh points Wine. Outside this folder it needs one udev rule,
# which lets your login use the stick.
#
#   zwift-ant.sh setup    build, wire up the Wine prefix, install the udev
#                         rule (asks for your password), then test
#   zwift-ant.sh status   what is built, for which Wine, and the stick
#   zwift-ant.sh test     a full test against the stick; close Zwift first
#   zwift-ant.sh remove   take it all out again (asks for your password)
#
# zwift.sh runs two more before every start:
#   zwift-ant.sh ensure   rebuild after a Wine upgrade and repair the prefix,
#                         asking for nothing. Exit status: 0 ready, 1 not
#                         usable, 2 turned off with remove, 3 usable, but
#                         read the message
#   zwift-ant.sh stick    prints "ready NODE", "locked NODE" or "missing"

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WINE_ROOT="${WINE_ROOT:-/opt/wine-staging}"
export WINEPREFIX="${WINEPREFIX:-$HERE/prefix}"
export WINEDEBUG="${WINEDEBUG:--all}"

# The library: upstream at a fixed commit, plus the patch. Once the patch is
# merged upstream, COMMIT can point at the merge and the patch go.
REPO="https://github.com/stanson-ch/libusb-wine.git"
COMMIT="644b03a1e1c69e1b6deb1e12e5c8c6813741561e"
ANT="$HERE/ant"
PATCH="$ANT/libusb-wine-ant.patch"
TEST_EXE="$ANT/ant-test.exe"
SRC="$ANT/src"                  # the patched source
LIB="$ANT/lib"                  # the build; zwift.sh puts it on WINEDLLPATH
SO="$LIB/x86_64-unix/libusb0.dll.so"
PLACEHOLDER="$LIB/libusb0.dll.fake"
STAMP="$LIB/built-for"          # the Wine version and patch it was built for
OFF="$ANT/turned-off"           # left by remove, so that ensure stays out

WINE="$WINE_ROOT/bin/wine"
SYS32="$WINEPREFIX/drive_c/windows/system32"
OVERRIDES='HKCU\Software\Wine\DllOverrides'
# Wine looks in its own folders before WINEDLLPATH: a copy there wins
SHADOWS="$WINE_ROOT/lib/wine/x86_64-unix/libusb0.dll.so $WINE_ROOT/lib64/wine/x86_64-unix/libusb0.dll.so"

RULE="${ZWIFT_UDEV_RULE:-/etc/udev/rules.d/70-ant-usb.rules}"
RULE_TEXT='# ANT+ USB sticks (Dynastream/Garmin), for Zwift under Wine
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0fcf", ATTR{idProduct}=="1008|1009", MODE="0660", GROUP="plugdev", TAG+="uaccess"'

# where the stick is looked for; tests point these elsewhere
SYSFS="${ZWIFT_SYSFS:-/sys}"
DEVUSB="${ZWIFT_DEVUSB:-/dev/bus/usb}"

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

is_placeholder() { [ -f "$1" ] && LC_ALL=C grep -aq 'Wine placeholder DLL' "$1"; }
# the match zwift.sh uses: a command line that starts with the program, so
# that an editor or a grep that mentions it does not count
zwift_running() { pgrep -f -- '^(.*\\)?Zwift(App|Launcher)\.exe([[:space:]]|$)' >/dev/null; }
wine_version() { "$WINE" --version 2>/dev/null; }
# what the build has to match: the Wine version and the patch
wanted_stamp() { wine_version; sha256sum "$PATCH" | cut -d' ' -f1; }
rule_installed() { cmp -s <(printf '%s\n' "$RULE_TEXT") "$RULE" 2>/dev/null; }

shadowing_copies() {
  local f
  for f in $SHADOWS; do [ -e "$f" ] && echo "$f"; done
  return 0
}

# The stick as the shell sees it: "ready NODE", "locked NODE" or "missing".
stick_state() {
  local d v p bus dev node
  for d in "$SYSFS"/bus/usb/devices/*; do
    { read -r v <"$d/idVendor" && read -r p <"$d/idProduct"; } 2>/dev/null || continue
    [ "$v" = 0fcf ] || continue
    case "$p" in 1008|1009) ;; *) continue ;; esac
    { read -r bus <"$d/busnum" && read -r dev <"$d/devnum"; } 2>/dev/null || continue
    node=$(printf '%s/%03d/%03d' "$DEVUSB" "$bus" "$dev")
    if [ -r "$node" ] && [ -w "$node" ]; then echo "ready $node"; else echo "locked $node"; fi
    return 0
  done
  echo missing
}

# the package with winegcc and Wine's headers, for the error message
dev_package() {
  case "${WINE_ROOT##*/}" in
    wine-staging|wine-stable|wine-devel) echo "${WINE_ROOT##*/}-dev" ;;
    *) echo "the development files of your Wine" ;;
  esac
}

build() {
  local tool sum
  for tool in gcc make git; do
    command -v "$tool" >/dev/null || { echo "$tool is missing: sudo apt install build-essential git" >&2; return 1; }
  done
  if [ ! -x "$WINE_ROOT/bin/winegcc" ] || [ ! -f "$WINE_ROOT/include/wine/windows/windef.h" ]; then
    echo "winegcc or Wine's headers are missing: sudo apt install $(dev_package)" >&2
    return 1
  fi

  # (re)make the source when it is missing or the patch has changed
  sum=$(sha256sum "$PATCH" | cut -d' ' -f1)
  if [ "$(cat "$SRC/.patch-sha256" 2>/dev/null)" != "$sum" ]; then
    rm -rf "$SRC.new"
    if ! { git clone --quiet "$REPO" "$SRC.new" &&
           git -C "$SRC.new" -c advice.detachedHead=false checkout --quiet "$COMMIT" &&
           git -C "$SRC.new" apply "$PATCH"; }; then
      rm -rf "$SRC.new"
      echo "could not get the source from $REPO" >&2
      return 1
    fi
    echo "$sum" >"$SRC.new/.patch-sha256"
    rm -rf "$SRC"
    mv "$SRC.new" "$SRC"
  fi

  # the objects depend on Wine's headers, so build from clean every time
  make -C "$SRC/src" -f Makefile.x64 clean >/dev/null 2>&1 || true
  if ! make -C "$SRC/src" -f Makefile.x64 WINE_INCLUDE="$WINE_ROOT/include/wine/windows" \
        WINEGCC="$WINE_ROOT/bin/winegcc" WINEBUILD="$WINE_ROOT/bin/winebuild" \
        >"$SRC/build.log" 2>&1; then
    tail -n 20 "$SRC/build.log" >&2
    echo "the build failed; the whole log is in $SRC/build.log" >&2
    return 1
  fi

  # swap the library in one step: a running Zwift keeps the file it has
  mkdir -p "$LIB/x86_64-unix"
  cp "$SRC/src/libusb0.dll.so" "$SO.new" && mv "$SO.new" "$SO"
  cp "$SRC/src/libusb0.dll.fake" "$PLACEHOLDER"
  wanted_stamp >"$STAMP"
}

# Is libusb0 set to builtin? Reading the registry file is all that a check
# before every start can afford, but a wineserver that is still running
# writes its changes to that file only every 30 seconds and when it exits.
# So a miss there is put to Wine itself, as is every check made "sure".
override_set() {
  local value
  if [ "${1:-}" != sure ] &&
     awk '/^\[/ { section = ($0 ~ /^\[Software\\\\Wine\\\\DllOverrides\]/) }
          section && /^"libusb0"="builtin"$/ { found = 1 }
          END { exit !found }' "$WINEPREFIX/user.reg" 2>/dev/null; then
    return 0
  fi
  value=$("$WINE" reg query "$OVERRIDES" /v libusb0 2>/dev/null | tr -d '\r') || return 1
  grep -qiE 'REG_SZ[[:space:]]+builtin$' <<<"$value"
}

# Wine loads a DLL only if a file of that name is where Windows would look,
# and the builtin override then makes it load this library, whatever that
# file is. So system32 needs some libusb0.dll: Wine's placeholder, or
# Zwift's own copy, which Wine puts back whenever it installs Zwift's ANT
# driver for a stick on a new port. Silent when nothing was wrong.
fix_prefix() {
  [ -d "$SYS32" ] || { echo "no Wine prefix at $WINEPREFIX" >&2; return 1; }
  if [ ! -e "$SYS32/libusb0.dll" ]; then
    cp "$PLACEHOLDER" "$SYS32/libusb0.dll"
    echo "put the libusb0 placeholder back into the prefix"
  fi
  if ! override_set "${1:-}"; then
    if "$WINE" reg add "$OVERRIDES" /v libusb0 /d builtin /f >/dev/null 2>&1; then
      echo "set libusb0 to builtin in the prefix"
    else
      echo "could not set the libusb0 override in the prefix" >&2
      return 1
    fi
  fi
}

cmd_ensure() {
  local err f attention=0
  [ -f "$OFF" ] && { echo "turned off; zwift-ant.sh setup turns it back on"; return 2; }
  [ -x "$WINE" ] || { echo "no Wine at $WINE_ROOT"; return 1; }
  if [ ! -f "$SO" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$(wanted_stamp)" ]; then
    if err=$(build 2>&1 >/dev/null); then
      echo "rebuilt for $(wine_version)"
    elif [ -f "$SO" ]; then
      echo "rebuilding failed, so the previous build is used: $(printf '%s\n' "$err" | tail -n 1)"
      attention=1
    else
      echo "cannot build: $(printf '%s\n' "$err" | tail -n 1)"
      return 1
    fi
  fi
  for f in $(shadowing_copies); do
    echo "Wine loads $f instead of this build; zwift-ant.sh setup removes it"
    attention=1
  done
  fix_prefix || return 1
  [ "$attention" = 0 ] || return 3
}

cmd_status() {
  local st f
  echo "Wine:      $(wine_version || echo "none in $WINE_ROOT")"
  if [ -f "$OFF" ]; then
    echo "ANT+:      turned off (zwift-ant.sh setup turns it back on)"
  elif [ -f "$SO" ]; then
    echo "Library:   built for $(head -n 1 "$STAMP" 2>/dev/null)"
    [ "$(cat "$STAMP" 2>/dev/null)" = "$(wanted_stamp)" ] ||
      echo "           out of date: the next start rebuilds it"
  else
    echo "Library:   not built: run zwift-ant.sh setup"
  fi
  if [ ! -f "$OFF" ]; then
    if [ -e "$SYS32/libusb0.dll" ] && override_set sure; then
      echo "Prefix:    set up"
    else
      echo "Prefix:    needs repair, which the next start does"
    fi
    if rule_installed; then echo "udev rule: $RULE"; else echo "udev rule: missing: run zwift-ant.sh setup"; fi
    for f in $(shadowing_copies); do
      echo "Problem:   Wine loads $f instead: run zwift-ant.sh setup"
    done
  fi
  st=$(stick_state)
  case "$st" in
    ready*)  echo "Stick:     plugged in, and yours to use (${st#ready })" ;;
    locked*) echo "Stick:     plugged in, but your login cannot use it (${st#locked }): run zwift-ant.sh setup" ;;
    *)       echo "Stick:     not plugged in" ;;
  esac
}

cmd_test() {
  [ -f "$SO" ] || die "not built yet: run zwift-ant.sh setup"
  [ -f "$TEST_EXE" ] || die "ant/ant-test.exe is missing"
  zwift_running && die "close Zwift first: the test needs the stick to itself"
  say "Testing (plug the stick in for the full test)"
  WINEDLLPATH="$LIB${WINEDLLPATH:+:$WINEDLLPATH}" "$WINE" "$TEST_EXE" 2>&1 | tr -d '\r' || true
}

cmd_setup() {
  local f
  say "Checking"
  [ -x "$WINE" ] || die "no Wine in $WINE_ROOT (set WINE_ROOT if it is somewhere else)"
  [ -d "$SYS32" ] || die "no Wine prefix at $WINEPREFIX"
  [ -f "$PATCH" ] || die "ant/libusb-wine-ant.patch is missing"
  zwift_running && die "close Zwift first"
  echo "Wine:   $(wine_version) in $WINE_ROOT"
  echo "Prefix: $WINEPREFIX"

  rm -f "$OFF"
  say "Building into $LIB"
  build || die "the build failed"
  echo "built for $(wine_version)"

  if [ -n "$(shadowing_copies)" ] || ! rule_installed; then
    say "System changes (asks for your password)"
    sudo -v
    for f in $(shadowing_copies); do
      sudo rm -f "$f"
      echo "removed $f, which Wine would have loaded instead of this build"
    done
    if ! rule_installed; then
      # numbered below 73, so that systemd's uaccess rule sees the tag:
      # whoever is logged in gets the stick, no group or new login needed
      sudo mkdir -p "$(dirname "$RULE")"
      printf '%s\n' "$RULE_TEXT" | sudo tee "$RULE" >/dev/null
      echo "wrote $RULE"
    fi
    if sudo udevadm control --reload-rules 2>/dev/null &&
       sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=0fcf 2>/dev/null; then
      sudo udevadm settle 2>/dev/null || true
    else
      echo "udev did not reload: unplug the stick and plug it back in"
    fi
  fi

  say "Wiring up the prefix"
  fix_prefix sure
  echo "done"

  cmd_test
}

cmd_remove() {
  zwift_running && die "close Zwift first"
  say "Restoring the prefix"
  if is_placeholder "$SYS32/libusb0.dll"; then
    rm -f "$SYS32/libusb0.dll"
    echo "removed the placeholder"
  fi
  "$WINE" reg delete "$OVERRIDES" /v libusb0 /f >/dev/null 2>&1 || true
  echo "removed the libusb0 override"

  say "Deleting the build (ant/src, ant/lib)"
  rm -rf "$SRC" "$LIB"
  touch "$OFF"

  if [ -e "$RULE" ]; then
    say "Removing the udev rule (asks for your password)"
    sudo rm -f "$RULE"
    echo "removed $RULE"
    sudo udevadm control --reload-rules 2>/dev/null || true
  fi
  echo
  echo "Done. zwift.sh still starts Zwift; zwift-ant.sh setup brings ANT+ back."
}

case "${1:-}" in
  setup)  cmd_setup ;;
  ensure) cmd_ensure ;;
  status) cmd_status ;;
  stick)  stick_state ;;
  test)   cmd_test ;;
  remove) cmd_remove ;;
  *)      sed -n '2,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
