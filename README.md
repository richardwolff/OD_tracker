# OD_tracker

Track bacterial culture growth: record OD<sub>600</sub> readings against a
per-culture stopwatch, fit a growth rate, and export the run as a zipped project folder (data CSV + project metadata text file + project record JSON).

**Import project** on the projects screen loads such a zip back in — on another
machine, or after the browser's storage was cleared. Zips exported before the
JSON record existed are rebuilt from their CSV and metadata report.

## Desktop launchers

Puts **OD Tracker** and **Send CSV by Email** in the applications menu and on
the desktop. Run it once, from this folder, on the machine that will use them:

```sh
bash install-launchers.sh
```

To remove both again:

```sh
bash install-launchers.sh --uninstall
```

Linux only — `.desktop` files are a freedesktop thing, so this is for the
Raspberry Pi or any Linux desktop. For a Mac see the next section. Nothing
needs root: everything lands under `$HOME`. The launchers carry the absolute
path to this folder, so if you move or rename it, re-run the script from the
new location.

The mailer needs Tkinter, which Raspberry Pi OS and Debian split into their own
package. The script warns if it is missing; install it with:

```sh
sudo apt install -y python3-tk
```

## Mac desktop app

Builds **OD Tracker.app** in `/Applications` and pins it to the Dock — a
native window around `index.html` with its own icon, menu bar and Save dialog
for exports. Run it once, from this folder:

```sh
bash install-mac-app.sh          # add --open to launch it straight away
```

The Dock restarts for a moment to show the new icon. To remove the app and its
Dock icon:

```sh
bash install-mac-app.sh --uninstall
```

It needs Apple's Command Line Tools for the Swift compiler (`xcode-select
--install` if the script says they are missing); nothing else, and no sudo.
The wrapper itself is `mac_app/main.swift`.

The app carries its own copy of `index.html`, so re-run the script after
editing the page. Cultures recorded in the app live in
`~/Library/WebKit/org.od-tracker.app/`, separate from any browser — export
projects as zips to back them up, and use **Import project** to bring in runs
exported from a browser or the Pi. Uninstalling leaves that data in place.

## Station Board

Lets people mark which station they are at, see who is at every other
station, and send them a request ("Can you come over?", "Your samples are
ready"). A request pops up in the upper right of OD Tracker on the station
that person is logged on at, and stays there until someone taps **Got it**.
If they log on somewhere else before then, it follows them.

One machine on the shared wifi hosts the board; a Pi is plenty. On that machine:

```sh
bash station_board/install-server.sh     # runs at every boot, port 8765
```

It asks for a board password and offers to turn on Tailscale Funnel (below),
then prints the address the stations need, e.g. `http://192.168.1.20:8765`.
To just try it, run `python3 station_board/server.py`. Give the host a fixed
address (a DHCP reservation on the router) so the stations keep finding it.

On each station Pi, `raspberry-pi-setup.sh` asks for the station's name, that
address and the password. You can also tap **Station** in OD Tracker's header
and fill them in there. Once it's set up, that button shows who is logged on and
opens the board, where people:

- **log on** by tapping their name (adding it the first time), and log off again
- see every station, who is there, and since when
- send a **request** to anyone logged on, from a list of one-tap messages or
  their own text

The board also works in any browser at the server's address. Add
`?station=<name>` to make that browser a station too.

### Password

One shared password for the lab, kept in `station_board/board-password` on the
host and readable only by its owner. A browser or station enters it once and
gets an access key back; only that key is stored, never the password. To
change it:

```sh
bash station_board/install-server.sh --password
```

That signs everyone out. Enter the new password in each station's Station
settings, or re-run `raspberry-pi-setup.sh` there. After five wrong passwords
in a minute, sign-in pauses for everyone for a minute.

The password keeps strangers out, but anyone who has it can still log anyone
on or off and send requests as anyone. Without a password file the board is
open to anyone who can reach it: fine on a lab network, never with Funnel.

### From other networks: Tailscale Funnel

Funnel gives the board a permanent public address, like
`https://board-pi.your-tailnet.ts.net`, so you can check it and send requests
from any wifi or phone. Only the host runs Tailscale; everyone else just opens
the link and enters the password. `install-server.sh` sets it up when you say
yes:

1. it installs Tailscale and asks you to sign the Pi in (open the printed link
   and log in, or create a free Tailscale account)
2. the first time, Tailscale prints another link to allow Funnel on your
   account; open it and approve
3. it prints the public address

Funnel needs a password, and the script won't turn it on without one.
`--uninstall` turns Funnel off again, along with any other Tailscale Serve
settings on that machine. The stations keep using the lab address.

Log-ons left running are cleared after 12 hours (`--expire-hours`). The roster,
log-ons and messages live in `station_board/board-state.json` on the host. On a
station the address and key passed by the kiosk launcher win at every boot, so
to change them, re-run `raspberry-pi-setup.sh`.
