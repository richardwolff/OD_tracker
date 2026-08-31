#!/bin/sh
# install.sh — put the mailer in the menu and on the desktop.
#
#     ./install.sh            install for the current user
#     ./install.sh --uninstall  take it back out
#
# Nothing here needs root: everything lands under $HOME. The .desktop file is
# generated rather than copied, because it has to carry the absolute path to
# wherever this folder actually lives.

set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NAME=send-csv-gui.desktop
APPS="$HOME/.local/share/applications"
DESKTOP=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$APPS/$NAME" "$DESKTOP/$NAME"
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$APPS" 2>/dev/null || true
    echo "Removed."
    exit 0
fi

[ -f "$DIR/send_csv.py" ]     || { echo "send_csv.py is missing from $DIR"; exit 1; }
[ -f "$DIR/send_csv_gui.py" ] || { echo "send_csv_gui.py is missing from $DIR"; exit 1; }
chmod +x "$DIR/send_csv.py" "$DIR/send_csv_gui.py"

# Tkinter is stdlib but split into its own package on Raspberry Pi OS/Debian,
# and its absence otherwise shows up as a window that never opens.
if ! python3 -c "import tkinter" >/dev/null 2>&1; then
    echo "Tkinter is missing. Install it, then run this again:"
    echo "    sudo apt install -y python3-tk"
    exit 1
fi

mkdir -p "$APPS"
sed "s|__DIR__|$DIR|g" "$DIR/$NAME" > "$APPS/$NAME"
chmod +x "$APPS/$NAME"

command -v desktop-file-validate >/dev/null 2>&1 &&
    desktop-file-validate "$APPS/$NAME" || true
command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$APPS" 2>/dev/null || true

if [ -d "$DESKTOP" ]; then
    cp "$APPS/$NAME" "$DESKTOP/$NAME"
    chmod +x "$DESKTOP/$NAME"
    # GNOME-derived desktops hide launchers they have not been told to trust;
    # the Pi's own file manager ignores this and is happy with the +x above.
    command -v gio >/dev/null 2>&1 &&
        gio set "$DESKTOP/$NAME" metadata::trusted true 2>/dev/null || true
    echo "Desktop icon:  $DESKTOP/$NAME"
else
    echo "No Desktop folder found — menu entry only."
fi

echo "Menu entry:    $APPS/$NAME"
echo "Done. Look under Office (or search \"Send CSV\") in the menu."
