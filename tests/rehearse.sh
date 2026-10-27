#!/usr/bin/env bash
# Rehearse the whole kit without Zwift and without an ANT+ stick: install,
# a first start that downloads the game, a ride with the stick pulled out
# and put back, a double click, zwift.sh killed mid-ride, a Wine upgrade, a
# damaged prefix, remove, setup again, and the stick test with no stick. It
# all happens in a throwaway home with its own Wine prefix; nothing outside
# it is touched.
#
#   tests/rehearse.sh
#   WINE_ROOT=/opt/wine-stable tests/rehearse.sh
#
# Stand-ins built from tests/stubs.c play Zwift's programs, libusb-wine's
# usbfs emulator (tests/usbemu.c in the patched source) plays the stick, a
# local web server plays Zwift's update server, and fake sudo, udevadm,
# notify-send and gnome-session-inhibit record what they are asked to do.
# Needs Wine with its development files, mingw-w64, gcc, git and python3.

set -uo pipefail

KIT_SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export WINE_ROOT="${WINE_ROOT:-/opt/wine-staging}"
T="$(mktemp -d "${TMPDIR:-/tmp}/zwift-rehearsal.XXXXXX")"
KIT="$T/home/Games/zwift"
ZDIR="$KIT/prefix/drive_c/Program Files (x86)/Zwift"
failed=0
server=

cleanup() {
  [ -n "$server" ] && kill "$server" 2>/dev/null
  WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -k 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
check() {   # check DESCRIPTION COMMAND...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $what"; else echo "  FAIL  $what"; failed=$((failed + 1)); fi
}
seen() { grep -q -- "$2" "$1"; }      # seen FILE PATTERN
unseen() { ! grep -q -- "$2" "$1"; }
count() { local n; n=$(grep -c -- "$2" "$1" 2>/dev/null); echo "${n:-0}"; }
# the inhibitor lets go up to a second after zwift.sh ends: wait for the Nth
settle() {
  local _
  for _ in $(seq 1 10); do
    [ "$(count "$T/awake.log" '^released')" -ge "$1" ] && return 0
    sleep 0.5
  done
}

step "Preparing the sandbox in $T"
mkdir -p "$T/home" "$T/bin" "$T/run" "$T/etc" "$T/cdn/Zwift_1.0.0/data" "$KIT/ant" "$KIT/tests"
cp "$KIT_SRC"/{README.md,install.sh,zwift.sh,zwift-ant.sh,zwift-fetch.py} "$KIT/"
cp "$KIT_SRC"/ant/{libusb-wine-ant.patch,ant-test.c,ant-test.exe} "$KIT/ant/"

# libusb-wine with the patch, for its usbfs emulator and headers
commit=$(sed -n 's/^COMMIT="\(.*\)"/\1/p' "$KIT/zwift-ant.sh")
if ! { git clone -q https://github.com/stanson-ch/libusb-wine.git "$T/libusb-wine" &&
       git -C "$T/libusb-wine" -c advice.detachedHead=false checkout -q "$commit" &&
       git -C "$T/libusb-wine" apply "$KIT/ant/libusb-wine-ant.patch"; }; then
  echo "cannot get libusb-wine"
  exit 1
fi
emu="$T/libusb-wine/tests/usbemu.c"
if ! { gcc -O2 -fPIC -shared -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -o "$T/usbemu.so" "$emu" -ldl -lpthread &&
       gcc -O2 -DUSBEMU_MKTREE -o "$T/usbemu-mktree" "$emu" && "$T/usbemu-mktree" "$T/usb"; }; then
  echo "cannot build the usbfs emulator"
  exit 1
fi

# the stick as sysfs shows it, for zwift.sh's own checks
mkdir -p "$T/sys/bus/usb/devices/1-1"
printf '%s\n' 0fcf >"$T/sys/bus/usb/devices/1-1/idVendor"
printf '%s\n' 1009 >"$T/sys/bus/usb/devices/1-1/idProduct"
printf '%s\n' 1 >"$T/sys/bus/usb/devices/1-1/busnum"
printf '%s\n' 5 >"$T/sys/bus/usb/devices/1-1/devnum"

# fakes for what would touch the system or the desktop; the $ in them is
# for when they run
# shellcheck disable=SC2016
{
  printf '#!/bin/sh\n[ "$1" = -v ] && exit 0\nexec "$@"\n' >"$T/bin/sudo"
  printf '#!/bin/sh\necho "udevadm $*" >>"%s/udevadm.log"\n' "$T" >"$T/bin/udevadm"
  printf '#!/bin/sh\nfor a; do last=$a; done\necho "$last" >>"%s/notifications.log"\n' "$T" >"$T/bin/notify-send"
  # like the real one, it holds the inhibition for as long as its command runs
  printf '#!/bin/sh\necho "held $*" >>"%s/awake.log"\nwhile [ "${1#--}" != "$1" ]; do shift 2; done\n"$@"\necho released >>"%s/awake.log"\n' \
    "$T" "$T" >"$T/bin/gnome-session-inhibit"
}
chmod +x "$T/bin/"*

# Zwift's programs; ZwiftApp.exe comes later, as a game "update"
mingw=x86_64-w64-mingw32-gcc
mkdir -p "$ZDIR"
if ! { $mingw -O2 -DLAUNCHER -o "$ZDIR/ZwiftLauncher.exe" "$KIT_SRC/tests/stubs.c" &&
       $mingw -O2 -DRFP -o "$ZDIR/RunFromProcess-x64.exe" "$KIT_SRC/tests/stubs.c" &&
       $mingw -O2 -DAPP -I"$T/libusb-wine/src" -o "$T/cdn/Zwift_1.0.0/ZwiftApp.exe" "$KIT_SRC/tests/stubs.c"; }; then
  echo "cannot build the stand-ins (is mingw-w64 installed?)"
  exit 1
fi
echo "release notes" >"$T/cdn/Zwift_1.0.0/data/notes.txt"

# Zwift's update server: a version file, a manifest, the files
python3 - "$T/cdn" <<'EOF'
import os, sys, zlib
root = sys.argv[1]
entries = []
for path in ("ZwiftApp.exe", "data\\notes.txt"):
    data = open(os.path.join(root, "Zwift_1.0.0", *path.split("\\")), "rb").read()
    crc = zlib.crc32(data)
    entries.append((path, len(data), crc - (1 << 32) if crc >= (1 << 31) else crc))
with open(os.path.join(root, "Zwift_ver_cur.xml"), "w") as f:
    f.write('<Zwift sversion="1.0.0 (rehearsal)" manifest="Zwift_1.0.0_manifest.xml"/>\n')
with open(os.path.join(root, "Zwift_1.0.0_manifest.xml"), "w") as f:
    f.write('<Manifest folder="Zwift_1.0.0">\n')
    for path, length, crc in entries:
        f.write("<file><path>{}</path><length>{}</length><checksum>{}</checksum></file>\n"
                .format(path, length, crc))
    f.write("</Manifest>\n")
EOF
port=$((20000 + RANDOM % 20000))
python3 -m http.server --bind 127.0.0.1 --directory "$T/cdn" "$port" >/dev/null 2>&1 &
server=$!

export HOME="$T/home" XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:$PATH"
export ZWIFT_SYSFS="$T/sys" ZWIFT_DEVUSB="$T/usb" ZWIFT_UDEV_RULE="$T/etc/70-ant-usb.rules"
export ZWIFT_CDN="http://127.0.0.1:$port" NO_PROXY="127.0.0.1" no_proxy="127.0.0.1"
export USBEMU_ROOT="$T/usb" USB_DEVFS_PATH="$T/usb" USBEMU_DRIVER=usb_serial_simple
export ZWIFT_STUB_OUT="$T/app.txt" ZWIFT_STUB_MS=9000 WINEDEBUG=-all

echo "creating a Wine prefix"
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineboot" -i >/dev/null 2>&1
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -w
export LD_PRELOAD="$T/usbemu.so"
sys32="$KIT/prefix/drive_c/windows/system32"

step "install.sh"
"$KIT/install.sh" >"$T/install.log" 2>&1
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -w      # saves the registry
check "the Zwift icon starts zwift.sh" seen "$HOME/.local/share/applications/zwift.desktop" "^Exec=.*\"$KIT/zwift.sh\"$"
check "the udev rule is written" test -f "$ZWIFT_UDEV_RULE"
check "the library is built into ant/lib" test -f "$KIT/ant/lib/x86_64-unix/libusb0.dll.so"
check "the prefix has the placeholder" seen "$sys32/libusb0.dll" "Wine placeholder DLL"
check "and the builtin override" seen "$KIT/prefix/user.reg" '"libusb0"="builtin"'
check "the stick test passed" seen "$T/install.log" "RESULT: ALL PASSED"

step "First start: the game comes as an update, then a ride"
"$KIT/zwift.sh" >"$T/start.log" 2>&1 &
start=$!
for _ in $(seq 1 120); do
  pgrep -f '^(.*\\)?ZwiftApp\.exe( |$)' >/dev/null && break
  sleep 0.5
done
sleep 3
mv "$T/sys/bus/usb/devices/1-1" "$T/sys/unplugged"          # pull the stick out
sleep 3
mv "$T/sys/unplugged" "$T/sys/bus/usb/devices/1-1"          # and put it back
wait "$start"
check "the update fetched the game" test -f "$ZDIR/ZwiftApp.exe"
check "and the rest of it" test -f "$ZDIR/data/notes.txt"
check "the game loaded the builtin library" seen "$T/app.txt" "loaded as C:\\\\windows\\\\system32\\\\libusb0.dll"
check "and opened the stick" seen "$T/app.txt" "ANT stick: opened 0FCF:1009"
check "and read from it" grep -qE "receive loop: [1-9][0-9]* reads" "$T/app.txt"
check "the unplug was announced" seen "$T/notifications.log" "unplugged"
check "and the stick's return" seen "$T/notifications.log" "plugged in"
check "the logs are in the kit folder" test -s "$KIT/logs/update.log"
settle 1
check "the laptop was kept awake from the click on" \
  seen "$T/awake.log" "^held --app-id zwift --reason Riding in Zwift --inhibit idle tail --pid="
check "and allowed to sleep again after the ride" test "$(count "$T/awake.log" '^released')" = 1

step "A second click while Zwift starts"
ZWIFT_STUB_MS=5000 "$KIT/zwift.sh" >"$T/first.log" 2>&1 &
start=$!
sleep 1
"$KIT/zwift.sh" >"$T/second.log" 2>&1
wait "$start"
check "the second start stands back" seen "$T/second.log" "already starting or running"
check "the first one went ahead" seen "$T/first.log" "Zwift is up"
settle 2
check "and only it kept the laptop awake" test "$(count "$T/awake.log" '^held')" = 2

step "zwift.sh killed mid-ride"
ZWIFT_STUB_MS=30000 "$KIT/zwift.sh" >"$T/killed.log" 2>&1 &
start=$!
for _ in $(seq 1 120); do
  pgrep -f '^(.*\\)?ZwiftApp\.exe( |$)' >/dev/null && break
  sleep 0.5
done
script=$(sed -n 's/^held .*--pid=\([0-9]*\) .*/\1/p' "$T/awake.log" | tail -n 1)
kill -9 "$script"
wait "$start"
settle 3
check "the laptop may sleep again" test "$(count "$T/awake.log" '^released')" = 3
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -k 2>/dev/null       # the game it left
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -w

step "A Wine upgrade"
sed -i '1s/.*/wine-0.0 (an older one)/' "$KIT/ant/lib/built-for"
"$KIT/zwift.sh" --check >"$T/upgrade.log" 2>&1
check "the next start rebuilds the library" seen "$T/upgrade.log" "rebuilt for"
check "for this Wine" seen "$KIT/ant/lib/built-for" "$("$WINE_ROOT/bin/wine" --version)"

step "A damaged prefix"
rm -f "$sys32/libusb0.dll"
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wine" reg delete 'HKCU\Software\Wine\DllOverrides' /v libusb0 /f >/dev/null 2>&1
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -w
# a wineserver that stays up, as it does during a ride: it writes changes
# to user.reg only every 30 seconds and when it exits
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -p30
"$KIT/zwift.sh" --check >"$T/repair.log" 2>&1
check "the placeholder is put back" seen "$sys32/libusb0.dll" "Wine placeholder DLL"
check "and the override set again" seen "$T/repair.log" "set libusb0 to builtin"
check "(which user.reg does not show yet)" unseen "$KIT/prefix/user.reg" '"libusb0"="builtin"'
"$KIT/zwift.sh" --check >"$T/again.log" 2>&1
check "so the next check asks Wine and repairs nothing" unseen "$T/again.log" "set libusb0"
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -k 2>/dev/null
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -w

step "zwift-ant.sh remove"
WINEPREFIX="$KIT/prefix" "$WINE_ROOT/bin/wineserver" -w
"$KIT/zwift-ant.sh" remove >"$T/remove.log" 2>&1
check "the udev rule is gone" test ! -e "$ZWIFT_UDEV_RULE"
check "the build is gone" test ! -e "$KIT/ant/lib"
check "the placeholder is gone" test ! -e "$sys32/libusb0.dll"
"$KIT/zwift.sh" --check >"$T/off.log" 2>&1
check "starts leave ANT+ off" seen "$T/off.log" "turned off"
check "and build nothing" test ! -e "$KIT/ant/lib"

step "zwift-ant.sh setup"
"$KIT/zwift-ant.sh" setup >"$T/setup.log" 2>&1
check "ANT+ is back and the test passes" seen "$T/setup.log" "RESULT: ALL PASSED"
check "the udev rule is back" test -f "$ZWIFT_UDEV_RULE"

step "The stick test without a stick"
mkdir -p "$T/no-usb"
USB_DEVFS_PATH="$T/no-usb" "$KIT/zwift-ant.sh" test >"$T/nostick.log" 2>&1
check "says that it tested only the library" seen "$T/nostick.log" "RESULT: PASSED, but without a stick"

step "The checks along the way"
check "no zwift.sh --check kept the laptop awake" test "$(count "$T/awake.log" '^held')" = 3

echo
if [ "$failed" = 0 ]; then
  echo "REHEARSAL PASSED"
else
  echo "$failed FAILED; the logs are in $T (kept)"
  trap - EXIT
  [ -n "$server" ] && kill "$server" 2>/dev/null
  exit 1
fi
