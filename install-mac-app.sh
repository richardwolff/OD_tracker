#!/usr/bin/env bash
#
# install-mac-app.sh — build OD Tracker as a Mac desktop app.
#
#     bash install-mac-app.sh              build and install /Applications/OD Tracker.app,
#                                          and pin it to the Dock
#     bash install-mac-app.sh --open       the same, then launch it
#     bash install-mac-app.sh --uninstall  remove the app and its Dock icon (data is kept)
#
# The app is a small native window around index.html (see mac_app/main.swift),
# compiled here with the Swift compiler from Apple's Command Line Tools. It
# carries its own copy of index.html, so re-run this after editing the page.
#
# Nothing here needs sudo: /Applications is writable by any admin user, and the
# app's data lands in ~/Library/WebKit. This is the macOS counterpart of install-launchers.sh;
# the .desktop launchers there are Linux-only.

set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/mac_app"
APP_NAME="OD Tracker"
APP="/Applications/$APP_NAME.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Info.plist" 2>/dev/null || echo org.od-tracker.app)"
DATA_DIR="$HOME/Library/WebKit/$BUNDLE_ID"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

# Pin to / unpin from the Dock by editing its preferences directly. `defaults`
# can append an entry but cannot remove one by content, so both directions go
# through plistlib. The Dock only rereads the file when restarted, and that
# blinks it for a second, so restart it only when something actually changed.
#     dock_pin add     -> 0 if added, 1 if already there
#     dock_pin remove  -> 0 if removed, 1 if it was not there
dock_pin() {
  python3 - "$1" "$APP" <<'PY'
import plistlib, subprocess, sys
from urllib.parse import quote, unquote, urlparse
mode, app = sys.argv[1], sys.argv[2]
raw = subprocess.run(["defaults", "export", "com.apple.dock", "-"],
                     capture_output=True, check=True).stdout
prefs = plistlib.loads(raw)
apps = prefs.setdefault("persistent-apps", [])
def path_of(tile):
    url = tile.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "")
    return unquote(urlparse(url).path).rstrip("/")
present = any(path_of(t) == app for t in apps)
if mode == "add":
    if present: sys.exit(1)
    apps.append({"tile-type": "file-tile",
                 "tile-data": {"file-data": {"_CFURLString": "file://" + quote(app) + "/",
                                             "_CFURLStringType": 15}}})
else:
    if not present: sys.exit(1)
    prefs["persistent-apps"] = [t for t in apps if path_of(t) != app]
subprocess.run(["defaults", "import", "com.apple.dock", "-"],
               input=plistlib.dumps(prefs), check=True)
PY
}

# ---------------------------------------------------------------- uninstall
if [[ "${1:-}" == "--uninstall" ]]; then
  say "Removing $APP_NAME"
  if [[ -d "$APP" ]]; then
    rm -rf "$APP" && info "removed $APP"
  else
    info "nothing at $APP"
  fi
  if dock_pin remove; then
    killall Dock 2>/dev/null || true
    info "removed the Dock icon"
  fi
  info "your cultures are untouched — they live in $DATA_DIR"
  info "delete that folder by hand if you want them gone too"
  exit 0
fi

OPEN_AFTER=0
case "${1:-}" in
  "")       ;;
  --open)   OPEN_AFTER=1 ;;
  *)        warn "unknown option: $1"
            warn "usage: bash install-mac-app.sh [--open | --uninstall]"
            exit 1 ;;
esac

# ---------------------------------------------------------------- checks
say "Checking what is here"
[[ "$(uname -s)" == "Darwin" ]] || { warn "this builds a Mac app — run it on macOS"; exit 1; }
[[ -f "$DIR/index.html" ]]      || { warn "index.html not found in $DIR"; exit 1; }
[[ -f "$SRC/main.swift" ]]      || { warn "missing $SRC/main.swift"; exit 1; }
[[ -f "$SRC/Info.plist" ]]      || { warn "missing $SRC/Info.plist"; exit 1; }

# swiftc ships with the Command Line Tools, which macOS offers to install on
# first use of any developer command. Check up front so the failure is clear.
if ! xcrun --find swiftc >/dev/null 2>&1; then
  warn "The Swift compiler is missing. Install Apple's Command Line Tools with:"
  warn "    xcode-select --install"
  warn "then run this script again."
  exit 1
fi
info "building from $DIR"

# ---------------------------------------------------------------- build
# Assemble in a temp folder and swap it in at the end, so a failed build never
# leaves a half-written app behind.
say "Compiling"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/od-tracker-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

xcrun swiftc -O \
  -target "$(uname -m)-apple-macosx11.3" \
  -framework Cocoa -framework WebKit \
  -o "$STAGE/Contents/MacOS/$APP_NAME" \
  "$SRC/main.swift"
info "compiled $APP_NAME"

# ---------------------------------------------------------------- bundle
say "Assembling the bundle"
cp "$SRC/Info.plist" "$STAGE/Contents/Info.plist"
# CFBundleVersion is the build stamp; it shows in the About panel, so you can
# tell which index.html an installed app carries.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

cp "$DIR/index.html" "$STAGE/Contents/Resources/index.html"
info "copied index.html"

# Icon: the same instrument photo the Linux launcher uses, padded square (it
# sits on white already) and rendered at every size macOS asks for.
if [[ -f "$DIR/genesys_30.png" ]] && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  W="$(sips -g pixelWidth  "$DIR/genesys_30.png" | awk '/pixelWidth/  {print $2}')"
  H="$(sips -g pixelHeight "$DIR/genesys_30.png" | awk '/pixelHeight/ {print $2}')"
  SIDE=$(( W > H ? W : H ))
  sips -s format png --padToHeightWidth "$SIDE" "$SIDE" --padColor FFFFFF \
       "$DIR/genesys_30.png" --out "$WORK/square.png" >/dev/null 2>&1
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"             "$WORK/square.png" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$WORK/square.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
  info "made the app icon"
else
  warn "genesys_30.png or iconutil missing — using the generic app icon"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$STAGE/Contents/Info.plist" 2>/dev/null || true
fi

# Ad-hoc signature: enough for a locally built app to launch cleanly and keep
# its identity (window position, data store) across rebuilds.
codesign --force --sign - "$STAGE" >/dev/null 2>&1 && info "signed (ad hoc)" \
  || warn "codesign failed — the app should still run, since it was built here"

# ---------------------------------------------------------------- install
say "Installing to $APP"
if [[ ! -w /Applications ]]; then
  warn "/Applications is not writable by this account (it is for admin users)."
  warn "Either run this from an admin account, or install for yourself only by"
  warn "changing APP= near the top of this script to \"\$HOME/Applications/...\"."
  exit 1
fi
rm -rf "$APP"
mv "$STAGE" "$APP"
touch "$APP"            # nudge Finder/Launch Services to pick up the new icon
info "installed"

say "Adding to the Dock"
if dock_pin add; then
  killall Dock 2>/dev/null || true
  info "pinned — the Dock restarts to show it"
else
  info "already in the Dock"
fi

# ---------------------------------------------------------------- done
say "Done"
info "Open it from the Dock, Spotlight, /Applications, or:   open \"$APP\""
info "After editing index.html, re-run this script to update the app."
info "Undo:  bash install-mac-app.sh --uninstall"
echo
warn "Cultures recorded in the app are stored in $DATA_DIR,"
warn "separately from any browser. Export projects as zips to back them up, and"
warn "use Import project to bring in ones exported from a browser or the Pi."

if [[ "$OPEN_AFTER" == 1 ]]; then
  open "$APP"
fi
