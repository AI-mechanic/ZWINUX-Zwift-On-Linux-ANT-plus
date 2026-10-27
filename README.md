# Zwift under Wine, with ANT+

Scripts that start Zwift under Wine on Linux, keep it up to date, and make
ANT+ USB sticks work in it.

- **Starting.** Zwift's launcher 1.2.0 exits a few seconds after it starts
  under Wine. `zwift.sh` starts the game from the launcher's process
  before that happens, which is all the game needs.
- **Updates.** The launcher is also what updates the game, so `zwift.sh`
  does that before every start, from Zwift's own servers.
- **ANT+.** Zwift talks to ANT+ sticks through `libusb0.dll`, which needs
  a Windows driver that Wine does not have. `zwift-ant.sh` builds a Wine
  version of it that talks to the stick through Linux's own USB support,
  and keeps it working when Wine is upgraded.
- **Checks.** Before every start you hear about a missing stick (and get
  15 seconds to plug it in), and during the ride about a stick that drops
  out or comes back.
- **The screen stays on.** Pedalling touches neither the keyboard nor the
  mouse, so GNOME would blank and lock the screen mid-ride, and perhaps
  suspend the laptop. From the click on the icon until Zwift exits, it
  does none of that; afterwards it blanks and locks as usual.

Tested on Ubuntu 26.04 with WineHQ's wine-staging 11.20 and an ANT USB-m
stick.

## What you need

- Zwift installed in a Wine prefix, with `RunFromProcess-x64.exe` in its
  Zwift folder, as the [zwift-on-linux](https://github.com/kaibae19/zwift-on-linux)
  installer sets it up.
- Wine from WineHQ. The scripts expect wine-staging in `/opt/wine-staging`;
  for wine-stable or wine-devel, or a Wine you built yourself, set
  `WINE_ROOT` to the folder that has its `bin/` and `include/`.
- For ANT+, the tools to build the library:

      sudo apt install build-essential git wine-staging-dev

  (`wine-stable-dev` or `wine-devel-dev` if that is your Wine.)

## Installing

Put this folder where it is to stay, for example `~/Games/zwift-tools`,
and run its installer with the path of your Wine prefix:

    ./install.sh ~/Games/zwift/prefix

If the prefix is in this folder, as `prefix`, leave the path out. For a
Wine other than `/opt/wine-staging`, put `WINE_ROOT=` in front, as in
`WINE_ROOT=/opt/wine-stable ./install.sh ~/Games/zwift/prefix`, here and
for the other commands below.

The installer points the Zwift icon at `zwift.sh` and sets up ANT+,
which asks for your password once, to install a udev rule. It ends with
a test against the stick, so plug the stick in first.

## Riding

Start Zwift from the app grid as usual. Everything else happens on its
own: the update, the checks, the rebuild after a Wine upgrade, and
keeping the screen on while you ride.

From a terminal:

    ./zwift.sh --check          # is everything ready? starts nothing
    ./zwift-ant.sh status       # ANT+ in detail
    ./zwift-ant.sh test         # a full test against the stick (Zwift closed)
    ./zwift-ant.sh setup        # set ANT+ up again
    ./zwift-ant.sh remove       # take ANT+ out again
    ./zwift-fetch.py --verify   # checksum every game file

`zwift-ant.sh setup` and `remove` ask for your password; `remove` leaves
Zwift working, just without ANT+.

## When something is wrong

| What you see | What to do |
|---|---|
| "The ANT+ stick is plugged in, but your login cannot use it" | `./zwift-ant.sh setup`, then unplug the stick and plug it back in |
| The test says "PASSED, but without a stick" with the stick in | the same |
| "ANT+ is unavailable: ... missing" | install what it names, then `./zwift-ant.sh setup` |
| "Wine loads ... instead of this build" | `./zwift-ant.sh setup` removes that older copy |
| A sensor missing after the stick came back | open the pairing screen in Zwift |
| The screen still blanks during a ride | `zwift.sh` asks GNOME to keep it on; on another desktop, switch screen blanking off while you ride |
| "Zwift did not start" | look at `logs/launcher.log` and the game log it points to |
| The update failed | `logs/update.log` says why; `./zwift-fetch.py` retries |

## What is where

| | |
|---|---|
| `zwift.sh` | starts Zwift; the icon runs it |
| `zwift-fetch.py` | game updates from Zwift's servers |
| `zwift-ant.sh` | ANT+ support |
| `install.sh` | the one-time setup |
| `ant/` | the library's patch, and the stick test with its source; `setup` adds the source (`ant/src`) and the build (`ant/lib`) |
| `prefix` | your Wine prefix, or a link to it |
| `logs/` | the launcher's output and the last update |
| `tests/` | a rehearsal of all of the above, without Zwift or a stick |

Outside this folder there are only the Zwift icon,
`~/.local/share/applications/zwift.desktop`, and the udev rule,
`/etc/udev/rules.d/70-ant-usb.rules`, which lets whoever is logged in use
an ANT+ stick.

## Updating these tools

They never update themselves; only the game does. To update them, put a
newer copy of this folder in place of the old one (or `git pull` if you
cloned it). Your prefix, logs and build stay where they are, and if the
library's patch changed, the next start rebuilds it.

## How it works

[HACKING.md](HACKING.md) explains each piece, why it is there, and how to
test a change. The ANT+ library is
[libusb-wine](https://github.com/stanson-ch/libusb-wine) with the patch in
`ant/`, which has also been offered upstream.

## Credits and licences

- [zwift-on-linux](https://github.com/kaibae19/zwift-on-linux) installs
  Zwift under Wine, and showed the way with RunFromProcess.
- [libusb-wine](https://github.com/stanson-ch/libusb-wine) by Andrew
  (Stanson) Kozin is the base of the ANT+ library; it in turn comes from
  libusb-win32 and libusb 0.1.
- Most of the code here was written with Claude, Anthropic's AI model,
  and tested on a real ANT+ stick.

The scripts and the stick test are under the MIT licence (`LICENSE`).
`ant/libusb-wine-ant.patch` changes libusb-wine and is, like it, under
the GNU LGPL 2.1.
