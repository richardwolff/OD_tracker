#!/usr/bin/env bash
#
# install-launchers.sh — put OD Tracker and the CSV mailer in the applications
# menu and on the desktop.
#
#     bash install-launchers.sh              install both, for the current user
#     bash install-launchers.sh --uninstall  take them back out
#
# Nothing here needs root: everything lands under $HOME. The .desktop files are
# generated from the templates in the repo rather than copied, because each one
# has to carry the absolute path to wherever this folder actually ended up.
#
# This is the plain desktop-icon install. For the Raspberry Pi kiosk — full
# screen at boot, no browser chrome — use raspberry-pi-setup.sh instead; the two
# are independent and can both be installed.

set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS="$HOME/.local/share/applications"
DESKTOP="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"

MAIL_DIR="$DIR/email_utility"

# template                              installed name          __DIR__ becomes
OD_TEMPLATE="$DIR/od_tracker.desktop";      OD_NAME="od-tracker.desktop"
MAIL_TEMPLATE="$MAIL_DIR/send-csv-gui.desktop"; MAIL_NAME="send-csv-gui.desktop"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

refresh_menu() {
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$APPS" 2>/dev/null || true
}

# ---------------------------------------------------------------- uninstall
if [[ "${1:-}" == "--uninstall" ]]; then
  say "Removing launchers"
  for name in "$OD_NAME" "$MAIL_NAME"; do
    for path in "$APPS/$name" "$DESKTOP/$name"; do
      [[ -e "$path" ]] && rm -f "$path" && info "removed $path"
    done
  done
  refresh_menu
  info "the repo itself is untouched — delete the folder by hand if you want it gone"
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  warn "unknown option: $1"
  warn "usage: bash install-launchers.sh [--uninstall]"
  exit 1
fi

# ---------------------------------------------------------------- install one
# Substitution is done in bash rather than with sed: a folder path containing &
# or | is legal on disk and would be mangled by a sed replacement.
install_entry() {
  local template="$1" name="$2" base="$3" line
  mkdir -p "$APPS"
  : > "$APPS/$name"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//__DIR__/$base}" >> "$APPS/$name"
  done < "$template"
  chmod +x "$APPS/$name"

  command -v desktop-file-validate >/dev/null 2>&1 &&
    desktop-file-validate "$APPS/$name" || true
  info "menu entry:   $APPS/$name"

  if [[ -d "$DESKTOP" ]]; then
    cp "$APPS/$name" "$DESKTOP/$name"
    chmod +x "$DESKTOP/$name"
    # GNOME-derived desktops hide launchers they have not been told to trust;
    # the Pi's own file manager ignores this and is happy with the +x above.
    command -v gio >/dev/null 2>&1 &&
      gio set "$DESKTOP/$name" metadata::trusted true 2>/dev/null || true
    info "desktop icon: $DESKTOP/$name"
  else
    warn "no Desktop folder at $DESKTOP — menu entry only"
  fi
}

# ---------------------------------------------------------------- checks
# Each app is checked on its own and installed on its own: a missing mailer
# should not cost you the OD Tracker icon, or the other way round.
say "Checking what is here"
[[ -f "$OD_TEMPLATE" ]]   || { warn "missing $OD_TEMPLATE"; exit 1; }
[[ -f "$MAIL_TEMPLATE" ]] || { warn "missing $MAIL_TEMPLATE"; exit 1; }

od_ok=1
[[ -f "$DIR/index.html" ]] || { warn "index.html not found in $DIR"; od_ok=0; }

mail_ok=1
for f in send_csv.py send_csv_gui.py; do
  [[ -f "$MAIL_DIR/$f" ]] || { warn "$f not found in $MAIL_DIR"; mail_ok=0; }
done
# Tkinter is stdlib but split into its own package on Raspberry Pi OS/Debian,
# and its absence otherwise shows up as a window that never opens. A warning,
# not a failure: the icon is still worth installing, and this is fixable later.
if [[ "$mail_ok" == 1 ]] && ! python3 -c "import tkinter" >/dev/null 2>&1; then
  warn "Tkinter is missing — the mailer window will not open until you run:"
  warn "    sudo apt install -y python3-tk"
fi

[[ "$od_ok" == 1 || "$mail_ok" == 1 ]] || { warn "nothing to install"; exit 1; }
info "installing from $DIR"

# ---------------------------------------------------------------- install
if [[ "$od_ok" == 1 ]]; then
  say "OD Tracker"
  chmod +x "$DIR/index.html" 2>/dev/null || true
  install_entry "$OD_TEMPLATE" "$OD_NAME" "$DIR"
fi

if [[ "$mail_ok" == 1 ]]; then
  say "Send CSV by Email"
  chmod +x "$MAIL_DIR/send_csv.py" "$MAIL_DIR/send_csv_gui.py" 2>/dev/null || true
  install_entry "$MAIL_TEMPLATE" "$MAIL_NAME" "$MAIL_DIR"
fi

refresh_menu

# ---------------------------------------------------------------- done
say "Done"
info "Search the menu for \"OD Tracker\" or \"Send CSV\", or use the desktop icons."
info "Undo:  bash install-launchers.sh --uninstall"
echo
warn "The launchers point at this folder. Move or rename it and they break —"
warn "re-run this script from the new location to repoint them."
