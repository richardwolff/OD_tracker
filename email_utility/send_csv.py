#!/usr/bin/env python3
"""
send_csv.py — email a CSV from the lab's Gmail account.

    python3 send_csv.py results.csv --to bench@lab.edu
    python3 send_csv.py Glycerol_growth_curves_8_17_2026.csv \
        --to alice@uni.edu,bob@uni.edu --subject "Overnight growth curves"

Stdlib only — nothing to install. Works with any CSV, whether it came out of
OD Tracker or anywhere else.

The password below is a Gmail *app password*, not the account password: Google
stopped accepting account passwords over SMTP in 2022. It is the one listed as
"send_email" at https://myaccount.google.com/apppasswords — revoke it there and
this script stops working, nothing else does.

Outlook is not an option, in case it comes up again: Microsoft finished
retiring password logins for SMTP on personal Outlook.com accounts on 30 April
2026, leaving OAuth2 as the only route, which smtplib cannot do on its own.

Anyone who can read this file can send mail as the lab. To keep it out of the
file, set OD_MAIL_PASSWORD in the environment instead and blank APP_PASSWORD:

    export OD_MAIL_PASSWORD='xxxx xxxx xxxx xxxx'
"""

import argparse
import mimetypes
import os
import smtplib
import socket
import ssl
import sys
from email.message import EmailMessage

SENDER       = "hwalabdata@gmail.com"
APP_PASSWORD = "gujs yprb dbiq aqtd"      # app "send_email"; or set OD_MAIL_PASSWORD
SMTP_HOST    = "smtp.gmail.com"
SMTP_PORT    = 587                        # 587 is STARTTLS; 465 would be SSL
TIMEOUT      = 30                         # seconds; a hung server should not hang the bench


def password():
    """The environment wins, so a shared machine need not hold the secret."""
    return (os.environ.get("OD_MAIL_PASSWORD") or APP_PASSWORD).replace(" ", "")


def parse_recipients(raw):
    """Accept "a@b.com, c@d.com" or repeated --to, and drop the empties."""
    out = []
    for chunk in raw:
        for addr in chunk.replace(";", ",").split(","):
            addr = addr.strip()
            if addr and addr not in out:
                out.append(addr)
    return out


def build_message(path, to, subject=None, body=None):
    """One message with the CSV attached, named after the file on disk."""
    with open(path, "rb") as fh:
        data = fh.read()

    name = os.path.basename(path)
    msg = EmailMessage()
    msg["From"] = SENDER
    msg["To"] = ", ".join(to)
    msg["Subject"] = subject or f"OD Tracker export — {name}"
    msg.set_content(body or f"{name} is attached.\n")

    # Trust the extension, but fall back to text/csv rather than guessing
    # application/octet-stream, which some mail clients refuse to preview.
    ctype, _ = mimetypes.guess_type(name)
    maintype, _, subtype = (ctype or "text/csv").partition("/")
    msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=name)
    return msg


def auth_failure_text(exc):
    """Gmail's rejection says only "username and password not accepted", which
    sends people off checking the address rather than the password."""
    if len(password()) != 16:
        return (f"Gmail rejected the login, and the password is "
                f"{len(password())} characters rather than 16 — that looks "
                "like an account password. It must be an app password from "
                "https://myaccount.google.com/apppasswords")

    return ("Gmail rejected the login. The app password may have been revoked "
            "— check the one named \"send_email\" at "
            "https://myaccount.google.com/apppasswords still exists, and that "
            "2-step verification is on for the account.")


def send(msg):
    context = ssl.create_default_context()
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=TIMEOUT) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
        smtp.login(SENDER, password())
        smtp.send_message(msg)


def main():
    ap = argparse.ArgumentParser(
        description="Email a CSV from " + SENDER,
        epilog="Example: python3 send_csv.py results.csv --to bench@lab.edu")
    ap.add_argument("csv", help="the CSV file to send")
    ap.add_argument("--to", required=True, action="append", metavar="ADDR",
                    help="recipient; repeat it or separate with commas")
    ap.add_argument("--subject")
    ap.add_argument("--body", help="message text (default: names the file)")
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would be sent, without sending it")
    args = ap.parse_args()

    if not os.path.isfile(args.csv):
        sys.exit(f"No such file: {args.csv}")

    to = parse_recipients(args.to)
    if not to:
        sys.exit("No recipient given.")

    if not password():
        sys.exit("No app password set — fill in APP_PASSWORD or set OD_MAIL_PASSWORD.")

    msg = build_message(args.csv, to, args.subject, args.body)
    size = os.path.getsize(args.csv)

    if args.dry_run:
        print(f"From:    {SENDER}")
        print(f"To:      {', '.join(to)}")
        print(f"Subject: {msg['Subject']}")
        print(f"Attach:  {os.path.basename(args.csv)} ({size:,} bytes)")
        print("\n(dry run — nothing sent)")
        return 0

    print(f"Sending {os.path.basename(args.csv)} ({size:,} bytes) to {', '.join(to)}…")
    try:
        send(msg)
    except (smtplib.SMTPAuthenticationError, smtplib.SMTPNotSupportedError,
            smtplib.SMTPSenderRefused) as exc:
        sys.exit(auth_failure_text(exc))
    except smtplib.SMTPRecipientsRefused:
        sys.exit("Gmail refused every recipient address.")
    except (socket.timeout, TimeoutError):
        sys.exit("Gmail did not answer in time.")
    except (socket.gaierror, ConnectionError, OSError) as exc:
        sys.exit(f"Could not reach {SMTP_HOST}:{SMTP_PORT} — {exc}")
    except smtplib.SMTPException as exc:
        sys.exit(f"Send failed: {exc}")

    print("Sent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
