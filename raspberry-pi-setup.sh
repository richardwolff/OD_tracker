#!/usr/bin/env bash
#
# Set up OD Tracker on a Raspberry Pi touch screen.
#
# Run this ON THE PI, in the folder containing index.html:
#     bash raspberry-pi-setup.sh            # an OD Tracker icon; opens when tapped
#     bash raspberry-pi-setup.sh --kiosk    # full-screen kiosk, started at every boot
#
# It will:
#   * install the app under ~/od-tracker
#   * add OD Tracker to the applications menu and the desktop; it opens in a
#     maximised window with touch sizing forced on, and closes like any window
#   * with --kiosk instead: open it full-screen with no way out but a keyboard,
#     and start it automatically at boot (a dedicated bench screen)
#   * let it use the camera without asking every time (a Chromium policy; asks for sudo)
#   * turn off screen blanking so the display stays awake
#   * optionally install an on-screen keyboard (for naming cultures)
#
# Re-running it without --kiosk turns an earlier kiosk install back into an icon.
# Nothing here needs the internet except the optional keyboard install.
# To undo everything:  bash raspberry-pi-setup.sh --uninstall

set -euo pipefail

APP_DIR="$HOME/od-tracker"
AUTOSTART_DIR="$HOME/.config/autostart"
DESKTOP_FILE="$AUTOSTART_DIR/od-tracker.desktop"
LAUNCHER="$APP_DIR/start-od-tracker.sh"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$HOME/.local/share/applications"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
ENTRY_NAME="od-tracker.desktop"        # the same name install-launchers.sh uses, so there's one icon
POLICY="/etc/chromium/policies/managed/od-tracker.json"
KIOSK=0
[[ "${1:-}" == "--kiosk" ]] && KIOSK=1

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

# Start-at-boot, by every mechanism a past install may have used
remove_autostart() {
  [[ -f "$DESKTOP_FILE" ]] && rm -f "$DESKTOP_FILE" && info "removed $DESKTOP_FILE"
  local WF="$HOME/.config/wayfire.ini" LB="$HOME/.config/labwc/autostart"
  if [[ -f "$WF" ]] && grep -q '^\s*od_tracker\s*=' "$WF"; then
    sed -i '/^\s*od_tracker\s*=/d' "$WF" && info "removed od_tracker from $WF"
  fi
  if [[ -f "$LB" ]] && grep -Fq "start-od-tracker.sh" "$LB"; then
    sed -i '/start-od-tracker\.sh/d' "$LB" && info "removed entry from $LB"
  fi
  return 0
}

# ---------------------------------------------------------------- uninstall
if [[ "${1:-}" == "--uninstall" ]]; then
  say "Removing OD Tracker's launchers"
  remove_autostart
  rm -f "$APPS_DIR/$ENTRY_NAME" "$DESKTOP_DIR/$ENTRY_NAME" && info "removed the menu and desktop icons"
  if [[ -f "$POLICY" ]]; then
    sudo rm -f "$POLICY" && info "removed the camera policy ($POLICY)" \
      || warn "couldn't remove $POLICY — run: sudo rm $POLICY"
  fi
  info "app files left in $APP_DIR (delete by hand if you want them gone)"
  info "screen blanking left off; re-enable via: sudo raspi-config"
  exit 0
fi

# ---------------------------------------------------------------- checks
say "Checking this is a Raspberry Pi"
if ! grep -qi raspberry /proc/device-tree/model 2>/dev/null && \
   ! grep -qi raspberry /proc/cpuinfo 2>/dev/null; then
  warn "This does not look like a Raspberry Pi."
  warn "Continuing anyway — but the launcher and blanking steps may not apply."
fi

say "Finding Chromium"
CHROMIUM=""
for c in chromium-browser chromium; do
  if command -v "$c" >/dev/null 2>&1; then CHROMIUM="$(command -v "$c")"; break; fi
done
if [[ -z "$CHROMIUM" ]]; then
  warn "Chromium not found. Install it with:"
  warn "    sudo apt update && sudo apt install -y chromium-browser"
  exit 1
fi
info "using $CHROMIUM"

if [[ ! -f "$SRC_DIR/index.html" ]]; then
  warn "index.html not found next to this script (looked in $SRC_DIR)."
  warn "Copy index.html and this script to the Pi together, then re-run."
  exit 1
fi

# ---------------------------------------------------------------- install
say "Installing app to $APP_DIR"
mkdir -p "$APP_DIR"
cp "$SRC_DIR/index.html" "$APP_DIR/index.html"
info "copied index.html"

# ---------------------------------------------------------------- station board
# Optional: name this Pi as a station on the Station Board (station_board/), so
# people can log on here and requests for them pop up in the corner of the app.
# STATION_NAME / BOARD_ADDR / BOARD_KEY in the environment skip the questions.
say "Station Board (optional)"
STATION_NAME="${STATION_NAME-}"
BOARD_ADDR="${BOARD_ADDR-}"
if [[ -z "$STATION_NAME" ]]; then
  read -r -p "  Name of this station, e.g. Bench 3 (blank to skip): " STATION_NAME || STATION_NAME=""
fi
if [[ -n "$STATION_NAME" && -z "$BOARD_ADDR" ]]; then
  read -r -p "  Board server address, e.g. http://192.168.1.20:8765: " BOARD_ADDR || BOARD_ADDR=""
fi
QUERY="touch=1"
if [[ -n "$STATION_NAME" && -n "$BOARD_ADDR" ]]; then
  enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
  [[ "$BOARD_ADDR" =~ ^https?:// ]] || BOARD_ADDR="http://$BOARD_ADDR"
  BOARD_ADDR="${BOARD_ADDR%/}"
  QUERY="$QUERY&station=$(enc "$STATION_NAME")&board=$(enc "$BOARD_ADDR")"
  info "this Pi is station \"$STATION_NAME\", board at $BOARD_ADDR"

  # A board with a password: trade it for the access key now, so a typo shows
  # up here, and only the key (never the password) goes into the launcher.
  BOARD_KEY="${BOARD_KEY-}"
  while [[ -z "$BOARD_KEY" ]]; do
    read -r -s -p "  Board password (blank if the board has none): " BOARD_PW || BOARD_PW=""; echo
    [[ -z "$BOARD_PW" ]] && break
    if BOARD_KEY="$(BOARD_PW="$BOARD_PW" python3 - "$BOARD_ADDR" <<'PY'
import json, os, sys, urllib.request, urllib.error
req = urllib.request.Request(sys.argv[1] + "/api/login", method="POST",
      data=json.dumps({"password": os.environ["BOARD_PW"]}).encode(),
      headers={"Content-Type": "application/json"})
try:
    print(json.load(urllib.request.urlopen(req, timeout=10))["key"])
except urllib.error.HTTPError as e:
    sys.exit("  ! " + json.load(e).get("error", f"server said {e.code}"))
except OSError as e:
    sys.exit(f"  ! can't reach the board server ({e})")
PY
    )"; then
      info "password accepted"
    else
      BOARD_KEY=""
      read -r -p "  Try again? [Y/n] " reply || reply=n
      [[ "$reply" == [nN]* ]] && break
    fi
  done
  unset BOARD_PW
  [[ -n "$BOARD_KEY" ]] && QUERY="$QUERY&boardkey=$(enc "$BOARD_KEY")"
else
  info "skipped — set it up later from the Station button in the app"
fi

# ---------------------------------------------------------------- launcher
# ?touch=1 forces the finger-sized layout. Some Pi panels report a fine
# pointer (and plugging in a mouse flips it), so we don't rely on detection.
# A window (the default) is Chromium's app mode: no address bar or tabs, a title
# bar with a close button, maximised. The kiosk is full-screen with no way out
# but a keyboard (Alt+F4), for a screen that does nothing else.
if (( KIOSK )); then
  say "Writing launcher (full-screen kiosk)"
  SHAPE='--kiosk \
  --start-fullscreen \'
else
  say "Writing launcher (a window)"
  SHAPE='--app="file://'"$APP_DIR"'/index.html?'"$QUERY"'" \
  --start-maximized \'
fi
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Launch OD Tracker. Generated by raspberry-pi-setup.sh.

# Keep the screen awake (X11 only; harmless and silent under Wayland).
if command -v xset >/dev/null 2>&1 && [[ -n "\${DISPLAY:-}" ]]; then
  xset s off        || true
  xset -dpms        || true
  xset s noblank    || true
fi

# Clear the "Chromium didn't shut down properly" bar, which otherwise appears
# every time the Pi loses power and needs a mouse click to dismiss.
PREFS="\$HOME/.config/chromium/Default/Preferences"
if [[ -f "\$PREFS" ]]; then
  sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' "\$PREFS" || true
fi

exec $CHROMIUM \\
  $SHAPE
  --touch-events=enabled \\
  --use-fake-ui-for-media-stream \\
  --noerrdialogs \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --disable-features=TranslateUI,WebRtcPipeWireCamera \\
  --no-first-run \\
  --fast --fast-start \\
  --password-store=basic \\
  --check-for-update-interval=31536000 \\
  --overscroll-history-navigation=0 \\
  $( (( KIOSK )) && printf '"file://%s/index.html?%s"' "$APP_DIR" "$QUERY" )
EOF
chmod 700 "$LAUNCHER"   # it can carry the board key
info "wrote $LAUNCHER"

# --use-fake-ui-for-media-stream answers the camera prompt with "allow", so
# Record OD's "Read from spectrophotometer" can use the bench camera: there is
# no one at a kiosk to click the prompt, and the page is a local file.
# WebRtcPipeWireCamera is switched off because Raspberry Pi OS's Chromium
# otherwise looks for cameras through PipeWire, which often doesn't pass USB
# webcams through: Chromium then sees no camera at all and the request waits
# forever. Off, it opens the webcam directly (V4L2).
# Those two only apply when this launcher is what starts Chromium: opened while
# another Chromium window is already up, the page joins that browser and its
# flags. The camera policy below covers that case; the PipeWire setting is also
# a chrome://flags switch, and the README says how to set it there.
# NOTE: deliberately NOT using --incognito or --guest. Those discard
# localStorage on exit, which would erase every culture at reboot.

# ---------------------------------------------------------------- camera policy
# A page opened from a file can't have its camera permission remembered, so
# without help Chromium asks at every reading. An administrator policy lets
# OD Tracker's page use the camera without asking, however Chromium was opened.
say "Camera permission (for Read from spectrophotometer)"
if [[ -f "$POLICY" ]]; then
  info "already set ($POLICY)"
else
  info "Lets OD Tracker use the camera without asking each time. Needs sudo, once."
  read -r -p "  Set it now? [Y/n] " reply || reply=y
  if [[ "$reply" != [nN]* ]]; then
    if sudo mkdir -p "$(dirname "$POLICY")" &&
       printf '{ "VideoCaptureAllowedUrls": ["file:///*", "file://*"] }\n' | sudo tee "$POLICY" >/dev/null; then
      info "set — restart Chromium for it to take effect; chrome://policy should list it as OK"
    else
      warn "couldn't write $POLICY; the camera will ask for permission each time"
    fi
  else
    info "skipped — the camera will ask for permission each time"
  fi
fi

# ---------------------------------------------------------------- icons
# OD Tracker in the applications menu and on the desktop, opening the launcher
say "Adding OD Tracker to the menu and desktop"
ICON="$APP_DIR/od-tracker.png"
[[ -f "$SRC_DIR/genesys_30.png" ]] && cp "$SRC_DIR/genesys_30.png" "$ICON"
mkdir -p "$APPS_DIR"
cat > "$APPS_DIR/$ENTRY_NAME" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=OD Tracker
GenericName=Bacterial growth tracker
Comment=Record OD600 readings and follow culture growth curves
Exec=$LAUNCHER
Icon=$ICON
Terminal=false
Categories=Science;Biology;Education;
Keywords=od;od600;growth;culture;bacteria;lab;
StartupNotify=false
EOF
info "menu: $APPS_DIR/$ENTRY_NAME"
if [[ -d "$DESKTOP_DIR" ]]; then
  cp "$APPS_DIR/$ENTRY_NAME" "$DESKTOP_DIR/$ENTRY_NAME"
  chmod +x "$DESKTOP_DIR/$ENTRY_NAME"
  # the file manager asks before running a desktop file it doesn't trust
  command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_DIR/$ENTRY_NAME" metadata::trusted true 2>/dev/null || true
  info "desktop: $DESKTOP_DIR/$ENTRY_NAME"
fi

# ---------------------------------------------------------------- autostart
# Only for the kiosk. Which mechanism works depends on the desktop session, and
# Raspberry Pi OS has changed this twice. Bookworm on a Pi 4/5 runs Wayland —
# Wayfire originally, labwc in later images — and neither reliably honours
# ~/.config/autostart. Pi 3 and older, and Bullseye, run X11/LXDE, which does.
if (( ! KIOSK )); then
  say "Not starting at boot"
  remove_autostart
  info "OD Tracker opens from its icon (use --kiosk to start it full-screen at boot)"
else
say "Setting up autostart at boot"

detect_session() {
  if pgrep -x labwc  >/dev/null 2>&1; then echo labwc;   return; fi
  if pgrep -x wayfire >/dev/null 2>&1; then echo wayfire; return; fi
  if [[ -f "$HOME/.config/wayfire.ini" ]]; then echo wayfire; return; fi
  if [[ -d "$HOME/.config/labwc" ]];      then echo labwc;   return; fi
  echo xdg
}
SESSION="$(detect_session)"
info "detected session: $SESSION"

case "$SESSION" in
  wayfire)
    WF="$HOME/.config/wayfire.ini"
    python3 - "$WF" od_tracker "$LAUNCHER" <<'PY'
import sys, re, pathlib
path, key, val = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text() if path.exists() else ""
line = f"{key} = {val}"
if re.search(rf"^\s*{re.escape(key)}\s*=", text, re.M):          # already there
    text = re.sub(rf"^\s*{re.escape(key)}\s*=.*$", line, text, flags=re.M)
elif re.search(r"^\[autostart\]", text, re.M):                    # section exists
    text = re.sub(r"^\[autostart\]", f"[autostart]\n{line}", text, count=1, flags=re.M)
else:                                                             # make the section
    text = (text.rstrip() + f"\n\n[autostart]\n{line}\n").lstrip("\n")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(text)
PY
    info "added od_tracker to [autostart] in $WF"
    ;;
  labwc)
    LB="$HOME/.config/labwc/autostart"
    mkdir -p "$(dirname "$LB")"
    [[ -f "$LB" ]] || printf '#!/bin/sh\n' > "$LB"
    if grep -Fq "$LAUNCHER" "$LB" 2>/dev/null; then
      info "already present in $LB"
    else
      printf '%s &\n' "$LAUNCHER" >> "$LB"
      info "appended to $LB"
    fi
    chmod +x "$LB" 2>/dev/null || true
    ;;
  *)
    mkdir -p "$AUTOSTART_DIR"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=OD Tracker
Comment=Bacterial culture OD tracker
Exec=$LAUNCHER
X-GNOME-Autostart-enabled=true
EOF
    info "wrote $DESKTOP_FILE"
    ;;
esac
fi

# ---------------------------------------------------------------- blanking
say "Turning off screen blanking"
if command -v raspi-config >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    sudo raspi-config nonint do_blanking 1 && info "screen blanking disabled"
  else
    warn "needs sudo — run this yourself:  sudo raspi-config nonint do_blanking 1"
  fi
else
  warn "raspi-config not found; disable blanking via your desktop settings"
fi

# ---------------------------------------------------------------- keyboard
say "On-screen keyboard (optional)"
info "The app has a built-in number pad, so recording an OD needs no keyboard."
info "You only need one to NAME a culture or type notes."
if command -v matchbox-keyboard >/dev/null 2>&1; then
  info "matchbox-keyboard already installed"
else
  read -r -p "  Install matchbox-keyboard now? [y/N] " reply || reply=n
  case "$reply" in
    [yY]*) sudo apt update && sudo apt install -y matchbox-keyboard && info "installed" ;;
    *)     info "skipped — install later with: sudo apt install matchbox-keyboard" ;;
  esac
fi

# ---------------------------------------------------------------- done
say "Done"
if (( KIOSK )); then
  info "Start it now:      $LAUNCHER"
  info "It also starts automatically at every boot."
  info "Exit kiosk mode:   Ctrl+Alt+F2, or press Alt+F4 with a keyboard attached"
else
  info "Open it:           the OD Tracker icon in the menu or on the desktop"
  info "                   (or run $LAUNCHER)"
  info "Close it:          the window's close button; your data stays"
fi
info "Undo everything:   bash raspberry-pi-setup.sh --uninstall"
echo
warn "Data lives in Chromium's profile on the SD card. Export CSV to a USB"
warn "stick regularly — an SD card failure or 'clear browsing data' loses it."
