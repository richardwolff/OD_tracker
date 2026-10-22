#!/usr/bin/env bash
#
# Run the Station Board server on this machine, starting at every boot, and
# optionally put it on the internet through Tailscale Funnel.
#
# Run it ON THE ONE PI (or other Linux box) that will host the board — the
# stations only need OD Tracker pointed at it:
#     bash station_board/install-server.sh            # port 8765
#     PORT=9000 bash station_board/install-server.sh
#
# It asks for:
#   * a board password (needed for Funnel; optional on a lab-only network),
#     kept in station_board/board-password, readable only by you
#   * whether to turn on Tailscale Funnel, which gives the board a public
#     https:// address so it can be checked from any wifi or phone
#
# The server runs as a systemd user service, so nothing needs root except
# Tailscale and, once, letting the service start before anyone logs in.
#
#     bash station_board/install-server.sh --password    # change the password
#     bash station_board/install-server.sh --uninstall   # remove the service and Funnel

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-8765}"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/station-board.service"
PWFILE="$DIR/board-password"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- password
# Asked twice, never echoed, written with no read access for anyone else.
set_password() {
  local a b
  while true; do
    read -r -s -p "  New board password (8+ characters): " a; echo
    if [[ ${#a} -lt 8 ]]; then warn "too short"; continue; fi
    read -r -s -p "  Again: " b; echo
    [[ "$a" == "$b" ]] && break
    warn "those didn't match"
  done
  ( umask 077; printf '%s\n' "$a" > "$PWFILE" )
  chmod 600 "$PWFILE"
  info "saved to $PWFILE"
}

restart_if_installed() {
  if [[ -f "$UNIT" ]]; then
    systemctl --user restart station-board.service && info "server restarted"
  fi
}

funnel_on() { command -v tailscale >/dev/null && tailscale funnel status 2>/dev/null | grep -q "Funnel on"; }

if [[ "${1:-}" == "--password" ]]; then
  say "Changing the board password"
  set_password
  restart_if_installed
  warn "Every browser and station is now signed out. Enter the new password in"
  warn "each station's Station settings (or re-run raspberry-pi-setup.sh there)."
  exit 0
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  say "Removing the Station Board service"
  if funnel_on; then
    # clears every Serve/Funnel setting on this machine, not just the board's
    sudo tailscale serve reset && info "Tailscale Funnel turned off"
  fi
  systemctl --user disable --now station-board.service 2>/dev/null || true
  rm -f "$UNIT" && info "removed $UNIT"
  systemctl --user daemon-reload || true
  info "left in $DIR: board-state.json (roster and messages) and board-password"
  exit 0
fi

command -v python3 >/dev/null || { warn "python3 not found"; exit 1; }
command -v systemctl >/dev/null || {
  warn "no systemd here — run the server by hand instead:"
  warn "    python3 $DIR/server.py --port $PORT"
  exit 1
}
[[ -f "$DIR/server.py" && -f "$DIR/board.html" ]] || { warn "server.py / board.html missing from $DIR"; exit 1; }

say "Board password"
if [[ -s "$PWFILE" ]]; then
  info "already set ($PWFILE) — change it with: bash $0 --password"
  chmod 600 "$PWFILE"
else
  info "Needed to reach the board from outside the lab. On a lab-only network"
  info "you can skip it, but then anyone on the wifi can use the board."
  read -r -p "  Set a password now? [Y/n] " reply || reply=y
  case "$reply" in
    [nN]*) info "skipped — the board is open to anyone who can reach it" ;;
    *)     set_password ;;
  esac
fi

say "Installing the Station Board service (port $PORT)"
mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<EOF
[Unit]
Description=Station Board server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$(command -v python3) $DIR/server.py --port $PORT --password-file $PWFILE
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
info "wrote $UNIT"

systemctl --user daemon-reload
systemctl --user enable station-board.service
systemctl --user restart station-board.service
info "started"

# A user service normally waits for that user to log in. Lingering starts it at
# boot instead, so the board is up even if this Pi's desktop never logs on.
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
  if sudo loginctl enable-linger "$USER"; then
    info "set to start at boot, before anyone logs in"
  else
    warn "could not enable lingering; the board will start when $USER logs in"
  fi
fi

# ---------------------------------------------------------------- funnel
# Funnel publishes the board at https://<machine>.<tailnet>.ts.net. Tailscale
# provides the certificate, and the connection is made outward from this Pi,
# so neither the router nor the lab network needs changing. Only this machine
# runs Tailscale; people opening the board need nothing but a browser.
say "Reach the board from other networks (Tailscale Funnel, optional)"
PUBLIC=""
if funnel_on; then
  info "already on"
elif [[ ! -s "$PWFILE" ]]; then
  info "skipped — Funnel puts the board on the internet, so it needs a password first."
  info "Set one with: bash $0 --password   then re-run this script."
else
  read -r -p "  Turn on Tailscale Funnel? [y/N] " reply || reply=n
  case "$reply" in
    [yY]*)
      if ! command -v tailscale >/dev/null; then
        info "installing Tailscale (needs the internet and sudo)"
        curl -fsSL https://tailscale.com/install.sh | sh
      fi
      if ! tailscale status >/dev/null 2>&1; then
        info "Sign this Pi in to Tailscale: open the link printed below on any device."
        sudo tailscale up
      fi
      # The first time, Tailscale prints a link to allow Funnel for this tailnet
      # (it switches on HTTPS certificates and the Funnel permission); open it,
      # approve, and the command carries on by itself.
      info "If a link appears, open it and approve Funnel for this machine."
      if sudo tailscale funnel --bg "$PORT"; then
        info "Funnel on — it comes back by itself after a reboot"
      else
        warn "Funnel did not start. Try by hand:  sudo tailscale funnel --bg $PORT"
      fi
      ;;
    *) info "skipped — turn it on later by re-running this script" ;;
  esac
fi
if funnel_on; then
  DNS="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
  [[ -n "$DNS" ]] && PUBLIC="https://$DNS"
fi

say "Done"
# The lab address: IPv4 and not Tailscale's own. Tailscale is asked which one
# is its own, not guessed from the 100.x range: some campus networks hand out
# lab addresses from that same range.
TSIP="$(tailscale ip -4 2>/dev/null || true)"
ADDR="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' \
        | grep -vxF "${TSIP:-none}" | head -1 || true)"
if [[ -n "$PUBLIC" ]]; then
  info "Board from anywhere:       $PUBLIC/"
  info "Address for each station:  $PUBLIC"
  info "Lab-only address:          http://${ADDR:-<this machine>}:$PORT"
  # Tailscale's firewall drops 100.64.0.0/10 traffic that didn't come through
  # Tailscale, which on a campus network using that range includes the stations
  case "$ADDR" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
      warn "This network uses 100.x addresses, like Tailscale, so Tailscale's firewall"
      warn "will probably block stations from the lab-only address. Use the https one." ;;
  esac
else
  info "Board on the lab network:  http://${ADDR:-<this machine>}:$PORT/"
  info "Address for each station:  http://${ADDR:-<this machine>}:$PORT"
fi
info "Logs:                      journalctl --user -u station-board -f"
warn "Give this Pi a fixed lab address (a DHCP reservation on the router) so the"
warn "stations can keep finding it after a reboot."
