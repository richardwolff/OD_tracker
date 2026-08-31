# OD_tracker

Track bacterial culture growth: record OD<sub>600</sub> readings against a
per-culture stopwatch, fit a growth rate, and export the run as CSV.
`index.html` is the whole app — one file, no build step, no server.

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

## Raspberry Pi kiosk

Separate from the launchers above, and independent of them — this one runs the
tracker full-screen in Chromium at every boot:

```sh
bash raspberry-pi-setup.sh
```
