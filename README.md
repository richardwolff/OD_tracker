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
Raspberry Pi or any Linux desktop, not macOS. Nothing needs root: everything
lands under `$HOME`. The launchers carry the absolute path to this folder, so
if you move or rename it, re-run the script from the new location.

The mailer needs Tkinter, which Raspberry Pi OS and Debian split into their own
package. The script warns if it is missing; install it with:

```sh
sudo apt install -y python3-tk
```
