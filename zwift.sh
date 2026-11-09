#!/usr/bin/env bash
# Start Zwift under Wine. The app-grid icon runs this.
#
# Before every start it updates the game from Zwift's servers
# (zwift-fetch.py), rebuilds the ANT+ library if Wine was upgraded
# (zwift-ant.sh ensure) and checks that the ANT+ stick is there. A small
# window shows how far it has got until the game is up; closing it stops
# the start. Until the game exits it keeps the screen on, and it tells you
# when the stick drops out or comes back.
#
#   zwift.sh                  check, update, start
#   zwift.sh --check          the checks only; starts nothing
#   SKIP_UPDATE=1 zwift.sh    start without looking for a game update
#   ZWIFT_WINDOW=0 zwift.sh   start without the window
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

# --- the window -------------------------------------------------------------
# From the click until the game is up, a small window says which of three
# steps the start is at, with one bar for the whole start; a download moves
# it by the byte. Closing the window, or Cancel, stops the start. zenity
# draws it. Without zenity or a desktop, or with ZWIFT_WINDOW=0, there is
# no window, and notifications say what matters; ZWIFT_WINDOW=1 asks for
# one even without a desktop in sight (the tests' fake zenity needs none).
UI=             # a file descriptor; what is written to it, the window shows
UI_PID=         # the process looking after the window
STEP=           # the window's first line: "Step 1 of 3 · Game update"
BAR_FROM=0      # where the bar stands when this step begins, in percent,
BAR_TO=0        # and where when it ends

window_open() {
  case "${ZWIFT_WINDOW:-}" in
    0) return 0 ;;
    1) ;;
    *) [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] || return 0 ;;
  esac
  command -v zenity >/dev/null 2>&1 || return 0
  exec {UI}> >(window_process)
  UI_PID=$!
}

# zenity reads the window's pipe. The pipe's end alone cannot close the
# window, because Wine and the other programs started from here inherit a
# copy of it; so the window also closes when this script's process is gone.
# Exit status 0: the window was up, and is now closed. 1: it went within a
# second and a half, too soon for anyone to have closed it, so it never
# opened (no display zenity could use, say), which is no reason to stop.
window_process() {
  local shown watcher since=${EPOCHREALTIME/[.,]/}
  zenity --progress --title Zwift --width 460 --auto-close --text "Starting Zwift" \
    <&0 >/dev/null 2>&1 &
  shown=$!
  tail --pid=$$ -f /dev/null </dev/null >/dev/null 2>&1 &
  watcher=$!
  wait -n "$shown" "$watcher"
  kill "$shown" "$watcher" 2>/dev/null
  [ $(( ${EPOCHREALTIME/[.,]/} - since )) -ge 1500000 ]
}

step() {   # step N HEADING FROM TO: step N of 3 begins, and takes the bar from FROM to TO
  STEP="Step $1 of 3 · $2" BAR_FROM=$3 BAR_TO=$4
}

# window PERCENT TEXT: PERCENT of this step is done, and TEXT is what is
# happening. PERCENT "busy" makes the bar pulse, for a wait of unknown length.
window() {
  local bar
  [ -n "$UI" ] || return 0
  case $1 in
    busy) bar=pulsate:true ;;
    ''|*[!0-9]*) return 0 ;;
    *) bar="pulsate:false"$'\n'$(( BAR_FROM + (BAR_TO - BAR_FROM) * $1 / 100 )) ;;
  esac
  window_write "$bar" "$2"
}

# window_says TEXT: the same, with the bar left where it is. Fails if there
# is no window, or it has gone, so that the caller can say it another way.
window_says() { [ -n "$UI" ] && kill -0 "$UI_PID" 2>/dev/null && window_write "" "$1"; }

window_write() {
  local text=${2//\\/\\\\}           # zenity reads backslashes as escapes,
  text=${text//$'\n'/ }              # and every line as a message of its own
  # A subshell writes, so that a window gone away cannot take this script
  # with it: writing to a pipe nobody reads ends the writer.
  (
    [ -z "$1" ] || printf '%s\n' "$1"
    printf '# %s\\n%s\n' "$STEP" "$text"
  ) 1>&"$UI" 2>/dev/null
  return 0
}

window_close() {   # the start is over
  [ -n "$UI" ] || return 0
  (printf 'pulsate:false\n100\n' >&"$UI") 2>/dev/null       # --auto-close
  exec {UI}>&-
  UI='' UI_PID=''
}

# Was the window closed, or Cancel pressed? Asked wherever the start can
# stop cleanly.
cancelled() {
  local status
  [ -n "$UI_PID" ] || return 1
  kill -0 "$UI_PID" 2>/dev/null && return 1
  wait "$UI_PID"
  status=$?
  exec {UI}>&-
  UI='' UI_PID=''
  [ "$status" = 0 ] && return 0
  echo "The window could not open; starting without it."
  return 1
}

stop() {   # stop [wine]: after a Cancel; "wine" also stops what Wine runs
  echo "Cancelled; Zwift is not started."
  [ "${1:-}" = wine ] && wineserver -k >/dev/null 2>&1
  exit 0
}

# --- messages ---------------------------------------------------------------
# Notifications, because the app grid gives no terminal. --check just prints.
# While the window is up, news goes there instead; warnings go to a
# notification too, which stays after the window has gone.
notify() {
  [ "$CHECK_ONLY" = 1 ] && return 0
  command -v notify-send >/dev/null 2>&1 &&
    notify-send -a Zwift "${ICON_ARGS[@]}" "$@" Zwift "$MSG" 2>/dev/null
  return 0
}
note() { MSG=$1; window_says "$1" || notify; echo "$1"; }
warn() { MSG=$1; window_says "$1"; notify -u critical; echo "$1" >&2; }
fail() {
  MSG=$1
  echo "$1" >&2
  if [ -n "$UI_PID" ] && kill -0 "$UI_PID" 2>/dev/null; then
    window_close
    zenity --error --title Zwift --no-markup --text "$1" </dev/null >/dev/null 2>&1 &
  else
    notify -u critical
  fi
  exit 1
}

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
DOWNLOADED=0
update_game() {
  [ "${SKIP_UPDATE:-0}" = 1 ] && { window 100 "Not looking for updates (SKIP_UPDATE=1)"; return 0; }
  [ -f "$FETCH" ] || { echo "zwift-fetch.py is missing; no update check"; return 0; }
  window busy "Looking for an update"
  python3 "$FETCH" --check "$ZDIR" >"$FETCHLOG" 2>&1
  case $? in
    0) window 100 "The game is up to date"; echo "Game: up to date" ;;
    3)
      if [ "$CHECK_ONLY" = 1 ]; then
        echo "Game: an update is waiting; the next start downloads it"
      else
        download_update
      fi
      ;;
    *) window 100 "The update check failed"; echo "Game: the update check failed (see $FETCHLOG)" ;;
  esac
}

# The download itself. zwift-fetch.py's --progress lines move the bar; the
# rest of its output goes to the log.
download_update() {
  local from fetch line
  cancelled && stop
  DOWNLOADED=1
  step 1 "Game update" 0 90             # the download is most of the start
  note "Downloading a Zwift update; this can take a while."
  exec {from}< <(exec python3 "$FETCH" --progress "$ZDIR" 2>&1)
  fetch=$!
  while IFS= read -r line <&"$from"; do
    case $line in
      "@progress "*)
        line=${line#@progress }
        window "${line%% *}" "Downloading the update: ${line#* }"
        ;;
      *) printf '%s\n' "$line" >>"$FETCHLOG" ;;
    esac
    if cancelled; then
      kill "$fetch" 2>/dev/null       # finished files stay; the next start fetches the rest
      stop
    fi
  done
  exec {from}<&-
  if wait "$fetch"; then
    note "Update complete."
  else
    warn "The update is incomplete (see $FETCHLOG); starting anyway."
  fi
}

# --- ANT+ -------------------------------------------------------------------
ANT_ON=0
ANT_READY=0
check_ant() {
  local out st n rc=0
  window busy "Checking ANT+ (after a Wine upgrade, a minute or two)"
  out=$(bash "$ANTCTL" ensure 2>&1) || rc=$?
  case $rc in
    0) ANT_ON=1; window 60 "ANT+ is ready"; [ -n "$out" ] && note "ANT+: $out" ;;  # it repaired something
    3) ANT_ON=1; window 60 ""; warn "ANT+: $out" ;;
    2) echo "ANT+: $out"; window 100 "ANT+ is turned off"; return 0 ;;
    *) window 100 ""; warn "ANT+ is unavailable: ${out:-zwift-ant.sh ensure failed}"; return 0 ;;
  esac

  st=$(bash "$ANTCTL" stick)
  if [ "$st" = missing ] && [ "$CHECK_ONLY" = 0 ]; then
    warn "The ANT+ stick is not plugged in. Plug it in; waiting 15 seconds."
    for n in $(seq 30 -1 1); do
      window 60 "Plug in the ANT+ stick; starting without it in $(( (n + 1) / 2 )) s"
      sleep 0.5
      cancelled && stop
      st=$(bash "$ANTCTL" stick)
      [ "$st" != missing ] && break
    done
    [ "$st" = missing ] && note "Starting without the ANT+ stick."
  fi
  case "$st" in
    ready*)  ANT_READY=1; window 100 "The ANT+ stick is ready"; echo "ANT+: stick ready (${st#ready })" ;;
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
window_open

step 1 "Game update" 0 20
update_game
cancelled && stop
[ -f "$ZDIR/ZwiftApp.exe" ] || fail "ZwiftApp.exe is missing; run: python3 $FETCH"

# after a download the bar is nearly full; otherwise starting is most of it
if [ "$DOWNLOADED" = 1 ]; then step 2 ANT+ 90 95; else step 2 ANT+ 20 40; fi
check_ant
cancelled && stop

step 3 "Starting Zwift" "$BAR_TO" 100
cd "$ZDIR" || fail "cannot enter $ZDIR"
window 0 "Starting the launcher"
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

window 40 "Starting the game"
echo "Launcher up; starting the game with RunFromProcess."
wine RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe 2>/dev/null || true

echo "Waiting for the game..."
window busy "Waiting for the game"
for _ in $(seq 1 90); do
  game_up && break
  cancelled && stop wine
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

window_close
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
