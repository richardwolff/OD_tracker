#!/usr/bin/env python3
"""
Station Board server: who is at which station, and the requests sent to them.

One machine on the shared wifi runs this (a Pi is plenty); every station, and
any laptop or phone on the same network, talks to it over plain HTTP. To reach
it from other networks, put it behind Tailscale Funnel (install-server.sh).

    python3 server.py                 # port 8765, state kept beside this file
    python3 server.py --port 9000 --data ~/board.json

It serves the board itself at  http://<this machine>:<port>/  and a small JSON
API under /api that the board and OD Tracker both use. Standard library only,
so nothing to pip install on the Pi.

Password: one shared password for the whole lab, read from the first line of
board-password beside this file (--password-file to put it elsewhere). Without
that file the board is open to anyone who can reach it — fine on a lab network,
never on the internet. With it, a browser or station trades the password once
for an access key (POST /api/login) and sends that key with every request in an
X-Board-Key header, so no device has to keep the password itself. Changing the
password changes the key, which signs everyone out. Anyone with the password
can still act as anyone: it keeps strangers out, not colleagues honest.

State
  people    the roster of names people tap to log on, kept sorted
  stations  every station that has checked in, with when it was last heard from
  presence  person -> the station they are logged on at, and since when
  messages  requests sent to a person; shown at the station they are at until
            someone taps "Got it"
"""

import argparse
import hashlib
import hmac
import json
import os
import socket
import sys
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent

MAX_NAME = 40          # a person's or a station's name
MAX_TEXT = 500         # one message
ONLINE_MS = 20_000     # a station polls every few seconds; silent this long = offline
KEEP_ACKED_MS = 24 * 3600_000   # acknowledged messages are kept a day, then dropped
MAX_MESSAGES = 500
LOGIN_FAILS = 5        # wrong passwords allowed per minute before logins pause


def now_ms():
    return int(time.time() * 1000)


def clean_name(v):
    """A display name: trimmed, inner whitespace collapsed, length-capped."""
    if not isinstance(v, str):
        return ""
    return " ".join(v.split())[:MAX_NAME]


class Board:
    """All state, behind one lock, written to disk after every change."""

    def __init__(self, path, expire_hours):
        self.path = Path(path)
        self.expire_ms = int(expire_hours * 3600_000)
        self.lock = threading.Lock()
        self.people = []
        self.stations = {}
        self.presence = {}
        self.messages = []
        self._load()

    # ---------------------------------------------------------------- disk
    def _load(self):
        try:
            data = json.loads(self.path.read_text())
        except FileNotFoundError:
            return
        except (OSError, ValueError) as err:
            # a corrupt file must not stop the board; keep it for inspection
            bad = self.path.with_suffix(f".corrupt-{int(time.time())}.json")
            self.path.rename(bad)
            print(f"! could not read {self.path} ({err}); moved it to {bad.name}")
            return
        self.people = [n for n in map(clean_name, data.get("people", [])) if n]
        self.stations = {k: v for k, v in data.get("stations", {}).items() if clean_name(k)}
        self.presence = data.get("presence", {})
        self.messages = data.get("messages", [])

    def _save(self):
        data = {"people": self.people, "stations": self.stations,
                "presence": self.presence, "messages": self.messages}
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=1))
        os.replace(tmp, self.path)   # atomic, so a power cut never leaves half a file

    # ---------------------------------------------------------------- housekeeping
    def _tidy(self, t):
        """Forget log-ons nobody ended, and messages long since dealt with."""
        changed = False
        if self.expire_ms > 0:
            for person, p in list(self.presence.items()):
                if t - p["since"] > self.expire_ms:
                    del self.presence[person]
                    changed = True
        keep = [m for m in self.messages
                if not m.get("ackAt") or t - m["ackAt"] < KEEP_ACKED_MS]
        keep = keep[-MAX_MESSAGES:]
        if len(keep) != len(self.messages):
            self.messages = keep
            changed = True
        return changed

    def _station_of_message(self, m):
        """A message follows its person: it shows wherever they are logged on
        now, and only falls back to where it was sent if they have left."""
        p = self.presence.get(m["to"])
        return p["station"] if p else m["station"]

    # ---------------------------------------------------------------- reads
    def snapshot(self, station=None):
        t = now_ms()
        with self.lock:
            changed = self._tidy(t)
            if station:
                # a station that asks for its view is a station that is on
                first = station not in self.stations
                self.stations[station] = {"lastSeen": t}
                # the heartbeat itself is not worth a disk write every few
                # seconds; only a brand-new station is
                changed = changed or first
            if changed:
                self._save()

            stations = []
            for name in sorted(self.stations, key=str.lower):
                here = sorted(({"name": p, "since": v["since"]}
                               for p, v in self.presence.items() if v["station"] == name),
                              key=lambda x: x["since"])
                stations.append({"name": name, "people": here,
                                 "online": t - self.stations[name]["lastSeen"] < ONLINE_MS})
            out = {
                "now": t,
                "stations": stations,
                "people": [{"name": n,
                            "station": self.presence.get(n, {}).get("station"),
                            "since": self.presence.get(n, {}).get("since")}
                           for n in self.people],
            }
            if station:
                out["messages"] = [m for m in self.messages
                                   if not m.get("ackAt") and self._station_of_message(m) == station]
            return out

    # ---------------------------------------------------------------- writes
    def add_person(self, name):
        with self.lock:
            if name.lower() not in (n.lower() for n in self.people):
                self.people.append(name)
                self.people.sort(key=str.lower)
                self._save()

    def remove_person(self, name):
        with self.lock:
            self.people = [n for n in self.people if n != name]
            self.presence.pop(name, None)
            self._save()

    def log_on(self, person, station):
        with self.lock:
            if person not in self.people:
                self.people.append(person)
                self.people.sort(key=str.lower)
            # one person, one station: logging on somewhere new moves them
            self.presence[person] = {"station": station, "since": now_ms()}
            self.stations.setdefault(station, {"lastSeen": now_ms()})
            self._save()

    def log_off(self, person):
        with self.lock:
            if self.presence.pop(person, None) is not None:
                self._save()

    def send(self, sender, to, text):
        with self.lock:
            p = self.presence.get(to)
            if not p:
                return None
            m = {"id": uuid.uuid4().hex[:12], "from": sender, "to": to,
                 "station": p["station"], "text": text, "at": now_ms(), "ackAt": None}
            self.messages.append(m)
            self._save()
            return m

    def ack(self, msg_id):
        with self.lock:
            for m in self.messages:
                if m["id"] == msg_id and not m.get("ackAt"):
                    m["ackAt"] = now_ms()
                    self._save()
                    return True
            return False

    def remove_station(self, station):
        with self.lock:
            self.stations.pop(station, None)
            for person in [p for p, v in self.presence.items() if v["station"] == station]:
                del self.presence[person]
            self._save()


class Gate:
    """The shared password, and the key it is traded for.

    The key is a slow hash of the password (PBKDF2), worked out once at start:
    a stolen key opens the board but is costly to turn back into a password
    that may be used elsewhere. There is no per-IP limit on guessing, because
    behind Funnel every request arrives from this machine; wrong passwords are
    capped for everyone at once instead, which slows a guesser to a crawl at
    the price of a minute's wait for anyone mistyping at the same time."""

    def __init__(self, password_file):
        self.key = None
        self.fails = []
        self.lock = threading.Lock()
        path = Path(password_file)
        try:
            password = path.read_text().splitlines()[0].strip()
        except (FileNotFoundError, IndexError):
            return
        if not password:
            return
        if path.stat().st_mode & 0o077:
            print(f"! {path} can be read by other users; run: chmod 600 {path}")
        self.key = self._key_for(password)

    @staticmethod
    def _key_for(password):
        return hashlib.pbkdf2_hmac("sha256", password.encode(), b"station-board-v1", 200_000).hex()

    @property
    def on(self):
        return self.key is not None

    def allows(self, key):
        return not self.on or (isinstance(key, str) and hmac.compare_digest(key, self.key))

    def login(self, password):
        """The key for a right password; None for a wrong one; raises
        PermissionError while logins are paused."""
        if not self.on:
            return ""
        t = time.monotonic()
        with self.lock:
            self.fails = [f for f in self.fails if t - f < 60]
            if len(self.fails) >= LOGIN_FAILS:
                raise PermissionError
        if isinstance(password, str) and hmac.compare_digest(self._key_for(password), self.key):
            return self.key
        with self.lock:
            self.fails.append(t)
        time.sleep(1)      # every wrong guess costs the guesser a second
        return None


class Handler(BaseHTTPRequestHandler):
    board: Board = None
    gate: Gate = None
    server_version = "StationBoard/1"

    # OD Tracker runs from file:// on the Pi and the board may be opened from any
    # machine, so every response allows any origin. Private-network preflights
    # (Chromium, page -> LAN address) are answered yes as well.
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Board-Key")
        self.send_header("Access-Control-Allow-Private-Network", "true")

    def _send(self, status, body=b"", ctype="application/json"):
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, status=HTTPStatus.OK):
        self._send(status, json.dumps(obj).encode())

    def _error(self, status, msg):
        self._json({"error": msg}, status)

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 16_384:
                return None
            data = json.loads(self.rfile.read(n) or b"{}")
            return data if isinstance(data, dict) else None
        except ValueError:
            return None

    def _authed(self):
        if self.gate.allows(self.headers.get("X-Board-Key")):
            return True
        self._error(HTTPStatus.UNAUTHORIZED, "password needed")
        return False

    def log_message(self, fmt, *args):
        # polling makes an access log useless; only errors are worth printing
        if args and str(args[1])[:1] in "45":
            super().log_message(fmt, *args)

    def do_OPTIONS(self):
        self._send(HTTPStatus.NO_CONTENT)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html", "/board.html"):
            try:
                body = (HERE / "board.html").read_bytes()
            except OSError:
                return self._error(HTTPStatus.NOT_FOUND, "board.html is missing beside server.py")
            return self._send(HTTPStatus.OK, body, "text/html; charset=utf-8")
        if url.path == "/api/state":
            if not self._authed():
                return
            station = clean_name(parse_qs(url.query).get("station", [""])[0])
            return self._json(self.board.snapshot(station or None))
        self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self):
        path = urlparse(self.path).path
        data = self._body()
        if data is None:
            return self._error(HTTPStatus.BAD_REQUEST, "expected a JSON object")
        b = self.board

        if path == "/api/login":
            try:
                key = self.gate.login(data.get("password"))
            except PermissionError:
                return self._error(HTTPStatus.TOO_MANY_REQUESTS,
                                   "Too many wrong passwords. Wait a minute and try again.")
            if key is None:
                return self._error(HTTPStatus.UNAUTHORIZED, "Wrong password.")
            return self._json({"key": key})
        if not self._authed():
            return

        if path == "/api/people":
            name = clean_name(data.get("name"))
            if not name:
                return self._error(HTTPStatus.BAD_REQUEST, "a name is required")
            b.add_person(name)
        elif path == "/api/people/remove":
            b.remove_person(clean_name(data.get("name")))
        elif path == "/api/logon":
            person, station = clean_name(data.get("person")), clean_name(data.get("station"))
            if not person or not station:
                return self._error(HTTPStatus.BAD_REQUEST, "person and station are required")
            b.log_on(person, station)
        elif path == "/api/logoff":
            b.log_off(clean_name(data.get("person")))
        elif path == "/api/messages":
            sender, to = clean_name(data.get("from")), clean_name(data.get("to"))
            text = str(data.get("text") or "").strip()[:MAX_TEXT]
            if not sender or not to or not text:
                return self._error(HTTPStatus.BAD_REQUEST, "from, to and text are required")
            if not b.send(sender, to, text):
                return self._error(HTTPStatus.CONFLICT, f"{to} is not logged on anywhere")
        elif path == "/api/messages/ack":
            b.ack(str(data.get("id") or ""))
        elif path == "/api/stations/remove":
            b.remove_station(clean_name(data.get("station")))
        else:
            return self._error(HTTPStatus.NOT_FOUND, "not found")

        self._json({"ok": True})


def lan_addresses():
    """This machine's addresses, for the startup message. A UDP 'connect' sends
    nothing; it only makes the OS pick the interface that route would use, so
    probing a few kinds of destination finds the lab address and, if this
    machine is on Tailscale, its Tailscale one too."""
    addrs = set()
    for probe in ("192.168.255.255", "10.255.255.255", "172.31.255.255", "8.8.8.8", "100.100.100.100"):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect((probe, 1))
                addrs.add(s.getsockname()[0])
        except OSError:
            pass
    return sorted(a for a in addrs if not a.startswith(("127.", "0.")))


def is_tailscale(addr):
    """Tailscale hands out addresses from 100.64.0.0/10 — reachable only from
    the same tailnet, so never the one to give a lab station."""
    a, b = (int(x) for x in addr.split(".")[:2])
    return a == 100 and 64 <= b <= 127


def main():
    ap = argparse.ArgumentParser(description="Station Board server")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="0.0.0.0",
                    help="address to listen on (default: every interface)")
    ap.add_argument("--data", default=str(HERE / "board-state.json"),
                    help="where the roster, log-ons and messages are kept")
    ap.add_argument("--password-file", default=str(HERE / "board-password"),
                    help="file whose first line is the board password (no file = no password)")
    ap.add_argument("--expire-hours", type=float, default=12,
                    help="log someone off after this long, in case they forgot (0 = never)")
    args = ap.parse_args()
    # under systemd stdout is a pipe, which Python buffers; the journal should
    # show each line as it happens
    sys.stdout.reconfigure(line_buffering=True)

    Handler.board = Board(Path(args.data).expanduser(), args.expire_hours)
    Handler.gate = Gate(Path(args.password_file).expanduser())
    httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    httpd.daemon_threads = True

    print(f"Station Board on port {args.port}  (state: {Handler.board.path})")
    print("  password: " + ("on" if Handler.gate.on else
                            f"OFF — anyone who can reach this port can use the board ({args.password_file})"))
    addrs = lan_addresses() if args.bind in ("0.0.0.0", "") else [args.bind]
    for a in addrs:
        tag = "  (Tailscale only — not for lab stations)" if is_tailscale(a) else ""
        print(f"  board address: http://{a}:{args.port}{tag}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
