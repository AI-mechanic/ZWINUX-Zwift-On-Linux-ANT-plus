# How the Zwift tools work

For whoever changes them next: what each piece does, why it is there, and
how to test a change without Zwift or a stick.

## A start, step by step

What `zwift.sh` does when the icon is clicked:

1. Takes a lock (`flock` on `$XDG_RUNTIME_DIR/zwift-start-UID.lock`), so a
   second click cannot run a second update and launcher. `flock -o` keeps
   the lock out of Wine's processes: a wineserver left behind can never
   hold it.
2. Asks GNOME to keep the session from going idle until the script ends
   (see below).
3. `zwift-fetch.py --check`: is the game up to date? If not, it downloads
   the update first (`logs/update.log`).
4. `zwift-ant.sh ensure`: rebuilds the ANT+ library if Wine or the patch
   changed, and repairs the prefix if something undid its settings. Its
   exit status says what to tell the rider (see below).
5. Looks for the stick in sysfs, and if it is missing, says so and waits up
   to 15 seconds for it.
6. Starts `ZwiftLauncher.exe`, and the moment its process exists,
   `RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe`, which starts
   the game as a child of the launcher's process.
7. Watches the game's process and the stick until the game exits, then
   waits three seconds (the game writes the ride's `.fit` file as it
   exits) and stops the prefix's wineserver.

Messages go to the terminal and, because the icon gives no terminal, to
`notify-send` as well. `zwift.sh --check` runs steps 3 to 5 without
downloading or starting anything.

### Why the screen stays on

GNOME counts only the keyboard and the mouse as activity, and a ride on a
trainer uses neither, so mid-ride it would dim, blank and lock the screen,
and with automatic suspend on, suspend the laptop. Windows programs keep
the display on with `SetThreadExecutionState()`, which Wine accepts and
ignores. So `keep_awake()` asks GNOME directly:

    gnome-session-inhibit --app-id zwift --reason "Riding in Zwift" \
        --inhibit idle tail --pid=$$ -f /dev/null </dev/null

An idle inhibitor stops all four, while a deliberate suspend (the lid, the
power menu) still works. gnome-session drops an inhibitor when its caller
leaves the bus, and `gnome-session-inhibit` leaves when its command ends.
That command waits for `zwift.sh`'s process, so the inhibitor cannot
outlive the script, even a killed one. Its input is `/dev/null` because,
given a terminal, `gnome-session-inhibit` hands the terminal to its
command, and Ctrl+C would then stop `tail` instead of `zwift.sh`. While
Zwift runs, `gnome-session-inhibit --list` shows the inhibitor as
`zwift: Riding in Zwift (idle)`.

### Why RunFromProcess

Launcher 1.2.0 draws its window with Windows.UI.Composition (WinRT), which
Wine only partly implements, and it exits about three seconds after it
starts. `ZwiftApp.exe` refuses to run unless it was started from the
launcher's process, but once running it no longer needs the launcher. So
the game is started from the launcher's process while that still exists.
`launcher_up()` and `game_up()` match the start of each process's command
line (`pgrep -f` with a pattern anchored at `^`), because under Wine the
game's `comm` is `main`, the launcher's is cut to 15 characters, and
RunFromProcess has both names in its own command line.

### Why zwift-fetch.py

Updating the game is the launcher's job, and the launcher exits before it
gets to it. `zwift-fetch.py` reads the same files from Zwift's servers:
`Zwift_ver_cur.xml` names the current manifest, the manifest lists every
file with its length and a CRC32 (as a signed 32-bit integer). A check
compares sizes only, because checksumming 5 GB before every ride would
take minutes; `--verify` checksums everything. Each download goes to a
`.part` file and replaces the old file only once its size and checksum
are right. Paths in the manifest that would leave the Zwift folder are
refused.

## ANT+

### The library

Zwift's `ANT_DLL.dll` uses `libusb0.dll`, the libusb-win32 library, whose
Windows driver Wine does not have.
[libusb-wine](https://github.com/stanson-ch/libusb-wine) is a Wine
builtin `libusb0.dll` that uses Linux's usbfs instead; in its released
form it does not work with 64-bit programs or with how `ANT_DLL` uses it.
`ant/libusb-wine-ant.patch` fixes that: the calling convention, the
asynchronous API, timeouts, errors, which devices it touches, and more,
with tests. Its own `HACKING.md`, in `ant/src/` after a setup, describes
it in detail. The patch is also a pull request upstream; once it is
merged, `COMMIT` in `zwift-ant.sh` can point at the merge and the patch
can go.

`zwift-ant.sh` clones upstream at a fixed commit, applies the patch into
`ant/src`, builds with the Wine in `WINE_ROOT`, and copies the result into
`ant/lib`. `ant/lib/built-for` records the Wine version and the patch's
SHA-256; when either differs, `ensure` rebuilds. A rebuild needs no
network unless the patch changed, and a failed rebuild keeps the previous
build in use.

### How Wine finds it

Three things have to be true, and `zwift.sh` and `ensure` see to them
before every start:

- `WINEDLLPATH` contains `ant/lib` (`zwift.sh` sets it), so that Wine finds
  `ant/lib/x86_64-unix/libusb0.dll.so`. Wine looks in its own folders
  first, so a `libusb0.dll.so` there would win; `ensure` warns about one,
  and `setup` removes it.
- A file called `libusb0.dll` is in the prefix's `system32`. Wine loads a
  DLL only if it finds a file by that name where Windows would look.
  `setup` puts Wine's placeholder there. When Zwift's ANT driver is
  installed for a stick on a new USB port, Wine's PnP code copies
  Zwift's own (Windows) `libusb0.dll` over it; that is fine, because of
  the next point.
- The DLL override `libusb0` is `builtin`, which makes Wine load the
  library from `ant/lib` whatever `libusb0.dll` it found. To keep the
  start quick, `ensure` looks for it in the prefix's `user.reg` instead
  of starting Wine. A wineserver that is still running writes that file
  only every 30 seconds and when it exits, so when the override is not
  there, `ensure` asks Wine (`wine reg query`) before it changes anything.

### The stick and udev

usbfs serves only those who may write to the device node. The udev rule
gives the stick (vendor `0fcf`, products `1008` and `1009`) the `uaccess`
tag, so systemd hands it to whoever is logged in at the screen; that only
works from a rules file numbered below 73. Linux also binds these sticks
to `usb_serial_simple`, as serial ports; the library takes the interface
from that driver when Zwift claims it.

### Exit codes between the scripts

`zwift-ant.sh ensure`, which `zwift.sh` reads:

| Status | Meaning | `zwift.sh` |
|---|---|---|
| 0 | ready; any output says what was repaired | a quiet notification if there was output |
| 1 | not usable (no Wine, build failed with no earlier build, prefix broken) | a warning; starts without ANT+ |
| 2 | turned off with `remove` | starts without ANT+, silently |
| 3 | usable, but needs attention (a rebuild failed, an older copy shadows it) | a warning; ANT+ stays on |

`zwift-fetch.py`: 0 up to date, 1 no manifest or no Zwift folder, 2
downloads failed, 3 (`--check`) an update is waiting, 4 (`--verify`)
files are corrupt.

## State

All of it is in this folder, apart from the icon and the udev rule:

| | |
|---|---|
| `ant/src` | the patched source; `.patch-sha256` says which patch it has |
| `ant/lib` | the build, and `built-for` |
| `ant/turned-off` | left by `remove`; `ensure` then does nothing until `setup` |
| `logs/` | `launcher.log` (the launcher's output), `update.log` (the last update) |
| `prefix` | the Wine prefix, or a link to it |

## Testing

`tests/rehearse.sh` runs the whole thing in a throwaway home with its own
Wine prefix: `install.sh`, a first start that downloads the game, a ride
with the stick pulled out and put back, a second click, `zwift.sh` killed
mid-ride, a Wine upgrade, a damaged prefix while a wineserver is still
running, `remove`, `setup`, and the stick test with no stick. Stand-ins
built from `tests/stubs.c` play Zwift's three programs; libusb-wine's usbfs
emulator plays the stick; a local web server plays Zwift's update server;
fake `sudo`, `udevadm`, `notify-send` and `gnome-session-inhibit` record
what they are asked. It
needs Wine with its development files, mingw-w64, gcc, git and python3,
and takes a few minutes:

    tests/rehearse.sh

Hooks it uses, which nothing else should need: `ZWIFT_SYSFS` and
`ZWIFT_DEVUSB` (where the stick is looked for), `ZWIFT_UDEV_RULE` (where
the rule goes), `ZWIFT_CDN` (where updates come from), and
`ZWIFT_STUB_MS` and `ZWIFT_STUB_OUT` for the stand-in game.

`ant/ant-test.exe` is the test against a real stick that `setup` and
`zwift-ant.sh test` run. It replays `ANT_DLL`'s own sequence, so
`RESULT: ALL PASSED` means Zwift will find the stick; without a stick it
tests only the library, and its result says so. Its source is `ant/ant-test.c`;
the command in its first comment rebuilds it, byte for byte with the same
version of mingw-w64 (13).

## When things change

- **A new Wine:** nothing to do; the next start rebuilds the library.
- **A new launcher:** if it starts working under Wine, `zwift.sh` can go
  back to starting it alone. If the game stops accepting a start from the
  launcher's process, step 6 is what needs looking at.
- **Another desktop:** `keep_awake()` is the only part that is GNOME's
  alone. Elsewhere it says it could not ask, and the screen blanks as
  usual, until it learns that desktop's way of holding off idle.
- **A new stick:** add its product ID to the udev rule in `zwift-ant.sh`
  and to `stick_state()` and `stick_present()`. If Linux binds it to a
  kernel driver, the library needs it on its `take_from_kernel[]` list too.
