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

## Reading the OD off the spectrophotometer

A USB webcam clamped in front of the GENESYS 30's screen (an EMEET C960 here,
30–40 cm away) lets Record OD read the number itself: tap **📷 Read from
spectrophotometer** and the OD box fills in, with a small picture of the screen
beside it to check before you tap Record.

Set it up once per station from the ⚙ beside that button: pick the camera, tick
**Picture upside down** if it hangs that way, and drag a box around the line
that reads **Value = …**. The setup screen shows what it reads as you go. If the
camera gets moved, draw the box again.

It reads the fixed d.ddd format by comparing each digit with examples of that
digit, built in from this instrument and added to by every reading saved after
a camera read, as long as the saved number keeps the screen's three decimals
(type 0.430, not 0.43, when correcting). A digit it isn't sure of, or three quick
looks that disagree (a number still settling), are flagged in red. Nothing
leaves the station: no network, no extra software.

On a Pi, `raspberry-pi-setup.sh` starts the kiosk with camera access allowed
(there is nobody to click the browser's prompt). In the Mac app, macOS asks once.

## Station Board

Lets people mark which stations they are at, see who is at every other
station, send them a request ("Can you come over?", "Your samples are
ready"), and chat about it. A message pops up in the upper right of OD Tracker
at every station its person is logged on at. It stays there until someone taps
**Got it**, or **Reply**, which opens the conversation with the sender. A
message to someone who isn't logged on anywhere waits, and pops up when they
next log on.

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
and fill them in there. Once it's set up, that button shows who is logged on
here. Its dot is green when someone is, orange when nobody is, and red when the
board can't be reached. Tapping it drops down the list of names: tap yours to
log on, **Log off** to leave, or **+ Add name**. The **Stations** button next
to it opens the board, where people:

- **log on** by tapping their name (adding it the first time). You can be
  logged on at several stations at once; **Log off** leaves only that station.
- see every station, who is there, and since when
- send a **request** to anyone logged on. Nobody is asked who's writing: it's
  whoever is logged on at that station (the most recent, if there are
  several), or whoever the device is set to with **I'm …**. **Change** sends
  as someone else on the list.
- **chat**: each conversation keeps its history. Replying counts as Got it.
- **send a project**: in a project, **Export project ▾ → Send…** sends its
  zip, the same one Download saves, to a person or to a station's screen, with
  an optional note. It's from whoever is logged on at the station.
  The message arrives with an **Import** button that loads the project in one
  tap (counting as Got it). In a chat, 📎 attaches a zip from disk instead, and
  any zip in a conversation can be downloaded. Only zip files, up to 25 MB, are
  accepted; they're kept in `station_board/board-files/` on the host and
  removed along with their message.
- leave a **message for a station**, with the **Message** button on its card,
  even when nobody is logged on there. It shows on that station's screen until
  someone there taps Got it or Reply. A reply goes to the sender, from whoever
  is logged on at that station (it asks someone to log on first if nobody is),
  and quotes the original note.

The board also works in any browser at the server's address. Tap **I'm …** to
say who that phone or laptop is for, and messages to you pop up there too. Add
`?station=<name>` to make that browser a station instead.

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

With Funnel on, point the stations at the `https://` address as well. It never
changes, so the host needs no fixed lab address. And on a network that hands
out 100.x addresses, as some campuses do, Tailscale's firewall blocks stations
from reaching the lab address at all.

Funnel needs a password, and the script won't turn it on without one.
`--uninstall` turns Funnel off again, along with any other Tailscale Serve
settings on that machine. The stations keep using the lab address.

Log-ons left running are cleared after 12 hours (`--expire-hours`), and
answered messages are kept for a week as chat history. The roster, log-ons and
messages live in `station_board/board-state.json` on the host. On a
station the address and key passed by the kiosk launcher win at every boot, so
to change them, re-run `raspberry-pi-setup.sh`.
