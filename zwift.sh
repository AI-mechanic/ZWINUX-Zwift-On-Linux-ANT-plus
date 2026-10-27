#!/usr/bin/env bash
# Start Zwift under Wine. The app-grid icon runs this.
#
# Before every start it updates the game from Zwift's servers
# (zwift-fetch.py), rebuilds the ANT+ library if Wine was upgraded
# (zwift-ant.sh ensure) and checks that the ANT+ stick is there. Until the
# game exits it keeps the screen on, and it tells you when the stick drops
# out or comes back.
#
#   zwift.sh                  check, update, start
#   zwift.sh --check          the checks only; starts nothing
#   SKIP_UPDATE=1 zwift.sh    start without looking for a game update
#
# Why the start is unusual: launcher 1.2.0 uses Windows.UI.Composition
# (WinRT), which Wine only partly provides, so it exits a few seconds after
# it starts, before it can show anything or update the game. ZwiftApp.exe
# only runs when started from the launcher's process, so RunFromProcess
# starts it from there the moment the launcher exists. The game does not
# need the launcher after that.

set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
export WINE_ROOT="${WINE_ROOT:-/opt/wine-staging}"
export WINEPREFIX="${WINEPREFIX:-$HERE/prefix}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---no-sandbox}"
# the ANT+ library lives in this folder; Wine looks there after its own
export WINEDLLPATH="$HERE/ant/lib${WINEDLLPATH:+:$WINEDLLPATH}"
if [ -x "$WINE_ROOT/bin/wine" ]; then export PATH="$WINE_ROOT/bin:$PATH"; fi

FETCH="$HERE/zwift-fetch.py"
ANTCTL="$HERE/zwift-ant.sh"
LOGS="$HERE/logs"
LOG="$LOGS/launcher.log"
FETCHLOG="$LOGS/update.log"
ZDIR="$WINEPREFIX/drive_c/Program Files (x86)/Zwift"
GAMELOG="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/AppData/Local/Zwift/Logs/Log.txt"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/zwift-start-$(id -u).lock"
SYSFS="${ZWIFT_SYSFS:-/sys}"     # tests point this elsewhere
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1
mkdir -p "$LOGS"

# Zwift's icon, under whatever name Wine gave it in this install
ICON=$(sed -n 's/^Icon=//p' "$HOME/.local/share/applications/zwift.desktop" 2>/dev/null | head -n 1)
ICON_ARGS=()
[ -n "$ICON" ] && ICON_ARGS=(-i "$ICON")

# Notifications, because the app grid gives no terminal. --check just prints.
notify() {
  [ "$CHECK_ONLY" = 1 ] && return 0
  command -v notify-send >/dev/null 2>&1 &&
    notify-send -a Zwift "${ICON_ARGS[@]}" "$@" Zwift "$MSG" 2>/dev/null
  return 0
}
note() { MSG=$1; notify; echo "$1"; }
warn() { MSG=$1; notify -u critical; echo "$1" >&2; }
fail() { warn "$1"; exit 1; }

# Process matching is fiddly under Wine: ZwiftApp's comm is "main", the
# launcher's is cut to 15 characters, and RunFromProcess carries both
# names in its own command line. So match the start of the command line,
# which is the program, with or without its Windows path.
running() { pgrep -f -- "$1" >/dev/null; }
launcher_up() { running '^(.*\\)?ZwiftLauncher\.exe([[:space:]]|$)'; }
game_up()     { running '^(.*\\)?ZwiftApp\.exe([[:space:]]|$)'; }

# Cheap enough to run every couple of seconds: builtins only.
stick_present() {
  local d v p
  for d in "$SYSFS"/bus/usb/devices/*; do
    { read -r v <"$d/idVendor" && read -r p <"$d/idProduct"; } 2>/dev/null || continue
    [ "$v" = 0fcf ] && case "$p" in 1008|1009) return 0 ;; esac
  done
  return 1
}

# --- game update ------------------------------------------------------------
# Zwift's launcher normally updates the game. Ours exits first, so do it
# here. A check is two small downloads and a look at the local file sizes,
# a second or two. Without a network the installed game may still run.
update_game() {
  [ "${SKIP_UPDATE:-0}" = 1 ] && return 0
  [ -f "$FETCH" ] || { echo "zwift-fetch.py is missing; no update check"; return 0; }
  python3 "$FETCH" --check "$ZDIR" >"$FETCHLOG" 2>&1
  case $? in
    0) echo "Game: up to date" ;;
    3)
      if [ "$CHECK_ONLY" = 1 ]; then
        echo "Game: an update is waiting; the next start downloads it"
      else
        note "Downloading a Zwift update; this can take a while."
        if python3 "$FETCH" "$ZDIR" >>"$FETCHLOG" 2>&1; then
          note "Update complete."
        else
          warn "The update is incomplete (see $FETCHLOG); starting anyway."
        fi
      fi
      ;;
    *) echo "Game: the update check failed (see $FETCHLOG)" ;;
  esac
}

# --- ANT+ -------------------------------------------------------------------
ANT_ON=0
ANT_READY=0
check_ant() {
  local out st rc=0
  out=$(bash "$ANTCTL" ensure 2>&1) || rc=$?
  case $rc in
    0) ANT_ON=1; [ -n "$out" ] && note "ANT+: $out" ;;   # it repaired something
    3) ANT_ON=1; warn "ANT+: $out" ;;
    2) echo "ANT+: $out"; return 0 ;;                     # turned off on purpose
    *) warn "ANT+ is unavailable: ${out:-zwift-ant.sh ensure failed}"; return 0 ;;
  esac

  st=$(bash "$ANTCTL" stick)
  if [ "$st" = missing ] && [ "$CHECK_ONLY" = 0 ]; then
    warn "The ANT+ stick is not plugged in. Plug it in; waiting 15 seconds."
    for _ in $(seq 1 30); do
      sleep 0.5
      st=$(bash "$ANTCTL" stick)
      [ "$st" != missing ] && break
    done
    [ "$st" = missing ] && note "Starting without the ANT+ stick."
  fi
  case "$st" in
    ready*)  ANT_READY=1; echo "ANT+: stick ready (${st#ready })" ;;
    locked*) warn "The ANT+ stick is plugged in, but your login cannot use it. Run: $ANTCTL setup" ;;
    *)       echo "ANT+: no stick plugged in" ;;
  esac
}

# During the ride: say so when the stick drops out or comes back.
watch_ride() {
  local was=0 now
  stick_present && was=1
  while game_up; do
    sleep 2
    [ "$ANT_ON" = 1 ] || continue
    now=0
    stick_present && now=1
    if [ "$was" = 1 ] && [ "$now" = 0 ]; then
      warn "The ANT+ stick was unplugged!"
    elif [ "$was" = 0 ] && [ "$now" = 1 ]; then
      note "ANT+ stick plugged in. If a sensor stays missing, open the pairing screen."
    fi
    was=$now
  done
}

# --- the screen -------------------------------------------------------------
# GNOME dims, blanks and locks the screen, and may suspend the laptop, once
# the keyboard and mouse have been idle a while, and a ride on a trainer
# touches neither. Windows programs keep the display on with
# SetThreadExecutionState(), which Wine accepts and ignores. So ask GNOME
# instead, from the click on the icon until this script ends. The request
# lasts as long as its command, and the command waits for this script's
# process, so even a killed script lets go.
keep_awake() {
  local pid
  if command -v gnome-session-inhibit >/dev/null 2>&1; then
    # stdin from /dev/null: given a terminal, it would hand that to tail
    gnome-session-inhibit --app-id zwift --reason "Riding in Zwift" --inhibit idle \
      tail --pid=$$ -f /dev/null </dev/null >/dev/null 2>&1 &
    pid=$!
    sleep 0.2                       # time enough for a refusal to come back
    kill -0 "$pid" 2>/dev/null && return 0
  fi
  echo "GNOME could not be asked to keep the screen on, so it may blank during the ride."
}

# --- main -------------------------------------------------------------------
command -v wine >/dev/null 2>&1 || fail "Wine not found (looked in $WINE_ROOT)"
[ -d "$ZDIR" ] || fail "Zwift is not installed at $ZDIR"

if [ "$CHECK_ONLY" = 1 ]; then
  update_game
  check_ant
  echo
  bash "$ANTCTL" status
  exit 0
fi

# One start at a time: a second click on the icon would otherwise run a
# second update and a second launcher. flock -o keeps the lock out of
# Wine's processes, so a wineserver left behind can never hold it.
if [ -z "${ZWIFT_LOCKED:-}" ] && command -v flock >/dev/null; then
  ZWIFT_LOCKED=1 flock -n -o -E 75 "$LOCK" "$BASH" "$SELF" "$@"
  status=$?
  [ "$status" = 75 ] && note "Zwift is already starting or running."
  [ "$status" = 75 ] && exit 0
  exit "$status"
fi

if game_up; then
  note "Zwift is already running."
  exit 0
fi

keep_awake
update_game
[ -f "$ZDIR/ZwiftApp.exe" ] || fail "ZwiftApp.exe is missing; run: python3 $FETCH"
check_ant

cd "$ZDIR" || fail "cannot enter $ZDIR"
echo "Starting the launcher (it exits after a few seconds; that is expected)."
wine ZwiftLauncher.exe >"$LOG" 2>&1 &

# Fire as soon as the process exists. RunFromProcess needs a live process,
# not a finished window, and the launcher lives about three seconds.
appeared=0
for _ in $(seq 1 80); do
  if launcher_up; then appeared=1; break; fi
  sleep 0.1
done
[ "$appeared" -eq 1 ] || fail "The launcher never appeared. See $LOG"

echo "Launcher up; starting the game with RunFromProcess."
wine RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe 2>/dev/null || true

echo "Waiting for the game..."
for _ in $(seq 1 90); do
  game_up && break
  sleep 1
done

if ! game_up; then
  echo "  launcher output: $LOG"
  if [ -f "$GAMELOG" ]; then
    echo "  the end of the game's log:"
    tail -n 15 "$GAMELOG" | sed 's/^/    /'
  else
    echo "  no game log: ZwiftApp never got going"
  fi
  fail "Zwift did not start."
fi

if [ "$ANT_READY" = 1 ]; then
  note "Zwift is up, and so is the ANT+ stick. Log in inside the game."
else
  note "Zwift is up. Log in inside the game."
fi

watch_ride

# The pause matters: ZwiftApp writes the ride's .fit file as it exits, and
# stopping wineserver too early cuts it short.
echo "The game has exited."
sleep 3
wineserver -k >/dev/null 2>&1 || true
