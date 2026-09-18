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
