#!/usr/bin/env python3
"""
send_csv_gui.py — a window around send_csv.py, for the bench machine.

Pick a file, type who it goes to, add a subject and a note, press Send. It
shells out to send_csv.py sitting next to it, so there is one copy of the
sending logic and the command line keeps working unchanged.

    python3 send_csv_gui.py                # empty form
    python3 send_csv_gui.py results.csv    # opens with that file attached

Needs Tkinter, which is stdlib but packaged separately on Raspberry Pi OS
and Debian:

    sudo apt install python3-tk
"""

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

HERE = os.path.dirname(os.path.abspath(__file__))
SENDER_SCRIPT = os.path.join(HERE, "send_csv.py")

# Gmail bounces anything much over 25 MB, and it does so only after the whole
# upload, so it is worth saying up front rather than after a long wait.
GMAIL_LIMIT = 25 * 1024 * 1024

RECENT_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "send_csv_gui", "recipients.txt")
RECENT_MAX = 8


def size_text(n):
    if n < 1024:
        return f"{n:,} bytes"
    if n < 1024 ** 2:
        return f"{n/1024:,.1f} KB"
    return f"{n/1024**2:,.1f} MB"


def load_recent():
    """Recipients typed before, so the same three addresses need typing once."""
    try:
        with open(RECENT_PATH, encoding="utf-8") as fh:
            return [line.strip() for line in fh if line.strip()]
    except OSError:
        return []


def save_recent(entry, existing):
    entry = entry.strip()
    if not entry:
        return existing
    kept = [entry] + [e for e in existing if e != entry]
    kept = kept[:RECENT_MAX]
    try:
        os.makedirs(os.path.dirname(RECENT_PATH), exist_ok=True)
        with open(RECENT_PATH, "w", encoding="utf-8") as fh:
            fh.write("\n".join(kept) + "\n")
    except OSError:
        pass          # a read-only home is not worth an error dialog
    return kept


class App:
    def __init__(self, root, initial_file=None):
        self.root = root
        self.results = queue.Queue()
        self.running = False
        self.recent = load_recent()

        root.title("Send a file by email")
        root.minsize(560, 460)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)

        style = ttk.Style()
        if "clam" in style.theme_names():        # default Pi theme is dated
            style.theme_use("clam")
        style.configure("TButton", padding=(10, 6))
        style.configure("Send.TButton", padding=(14, 8))
        style.configure("Hint.TLabel", foreground="#555555")
        style.configure("Err.TLabel", foreground="#a11")
        style.configure("Ok.TLabel", foreground="#161")

        frame = ttk.Frame(root, padding=14)
        frame.grid(row=0, column=0, sticky="nsew")
        frame.columnconfigure(1, weight=1)
        frame.rowconfigure(5, weight=1)
        row = 0

        # --- attachment ---------------------------------------------------
        ttk.Label(frame, text="Attachment").grid(row=row, column=0, sticky="w",
                                                 pady=(0, 2))
        picker = ttk.Frame(frame)
        picker.grid(row=row, column=1, sticky="ew", pady=(0, 2))
        picker.columnconfigure(0, weight=1)
        self.file_var = tk.StringVar()
        self.file_entry = ttk.Entry(picker, textvariable=self.file_var)
        self.file_entry.grid(row=0, column=0, sticky="ew")
        ttk.Button(picker, text="Browse…", command=self.browse).grid(
            row=0, column=1, padx=(8, 0))
        row += 1

        self.file_hint = ttk.Label(frame, text="", style="Hint.TLabel")
        self.file_hint.grid(row=row, column=1, sticky="w", pady=(0, 10))
        self.file_var.trace_add("write", lambda *_: self.describe_file())
        row += 1

        # --- recipients -----------------------------------------------------
        ttk.Label(frame, text="To").grid(row=row, column=0, sticky="w")
        self.to_var = tk.StringVar()
        self.to_box = ttk.Combobox(frame, textvariable=self.to_var,
                                   values=self.recent)
        self.to_box.grid(row=row, column=1, sticky="ew")
        row += 1
        ttk.Label(frame, text="separate several with commas",
                  style="Hint.TLabel").grid(row=row, column=1, sticky="w",
                                            pady=(0, 10))
        row += 1

        # --- subject --------------------------------------------------------
        ttk.Label(frame, text="Subject").grid(row=row, column=0, sticky="w")
        self.subject_var = tk.StringVar()
        ttk.Entry(frame, textvariable=self.subject_var).grid(
            row=row, column=1, sticky="ew", pady=(0, 10))
        row += 1

        # --- body -----------------------------------------------------------
        ttk.Label(frame, text="Message").grid(row=row, column=0, sticky="nw")
        body_wrap = ttk.Frame(frame)
        body_wrap.grid(row=row, column=1, sticky="nsew")
        body_wrap.columnconfigure(0, weight=1)
        body_wrap.rowconfigure(0, weight=1)
        self.body = tk.Text(body_wrap, height=7, wrap="word",
                            font=("TkDefaultFont", 10), undo=True)
        self.body.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(body_wrap, command=self.body.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.body.configure(yscrollcommand=scroll.set)
        row += 1

        ttk.Label(frame, text="leave either blank to let the script fill it in",
                  style="Hint.TLabel").grid(row=row, column=1, sticky="w",
                                            pady=(4, 12))
        row += 1

        # --- buttons --------------------------------------------------------
        buttons = ttk.Frame(frame)
        buttons.grid(row=row, column=0, columnspan=2, sticky="ew")
        buttons.columnconfigure(0, weight=1)
        self.status = ttk.Label(buttons, text="", style="Hint.TLabel",
                                wraplength=380, justify="left")
        self.status.grid(row=0, column=0, sticky="w")
        self.check_btn = ttk.Button(buttons, text="Check",
                                    command=lambda: self.start(dry_run=True))
        self.check_btn.grid(row=0, column=1, padx=(8, 6))
        self.send_btn = ttk.Button(buttons, text="Send", style="Send.TButton",
                                   command=lambda: self.start(dry_run=False))
        self.send_btn.grid(row=0, column=2)

        if initial_file:
            self.file_var.set(os.path.abspath(initial_file))
        self.describe_file()

        root.bind("<Control-Return>", lambda _e: self.start(dry_run=False))
        self.to_box.focus_set()
        self.root.after(120, self.drain)

    # -- file ----------------------------------------------------------------
    def browse(self):
        start = os.path.dirname(self.file_var.get()) or os.path.expanduser("~")
        path = filedialog.askopenfilename(
            parent=self.root, title="Choose a file to attach",
            initialdir=start if os.path.isdir(start) else os.path.expanduser("~"),
            filetypes=[("CSV files", "*.csv"), ("All files", "*")])
        if path:
            self.file_var.set(path)

    def describe_file(self):
        path = self.file_var.get().strip()
        if not path:
            self.file_hint.configure(text="nothing chosen yet",
                                     style="Hint.TLabel")
            return
        if not os.path.isfile(path):
            self.file_hint.configure(text="no such file", style="Err.TLabel")
            return
        size = os.path.getsize(path)
        text = f"{os.path.basename(path)} — {size_text(size)}"
        if size > GMAIL_LIMIT:
            self.file_hint.configure(
                text=text + "; over Gmail's 25 MB limit, this will bounce",
                style="Err.TLabel")
        else:
            self.file_hint.configure(text=text, style="Hint.TLabel")

    # -- sending -------------------------------------------------------------
    def command(self, dry_run):
        cmd = [sys.executable, SENDER_SCRIPT, self.file_var.get().strip(),
               "--to", self.to_var.get().strip()]
        subject = self.subject_var.get().strip()
        if subject:
            cmd += ["--subject", subject]
        body = self.body.get("1.0", "end").strip()
        if body:
            cmd += ["--body", body + "\n"]
        if dry_run:
            cmd.append("--dry-run")
        return cmd

    def start(self, dry_run):
        if self.running:
            return

        path = self.file_var.get().strip()
        if not path:
            return self.complain("Choose a file to attach first.")
        if not os.path.isfile(path):
            return self.complain(f"No such file:\n{path}")
        if not self.to_var.get().strip():
            return self.complain("Fill in at least one recipient.")
        if not os.path.isfile(SENDER_SCRIPT):
            return self.complain(f"send_csv.py is missing — it should sit "
                                 f"beside this window at:\n{SENDER_SCRIPT}")

        self.running = True
        self.send_btn.state(["disabled"])
        self.check_btn.state(["disabled"])
        self.status.configure(
            text="Checking…" if dry_run else "Sending…", style="Hint.TLabel")

        cmd = self.command(dry_run)
        threading.Thread(target=self.run, args=(cmd, dry_run),
                         daemon=True).start()

    def run(self, cmd, dry_run):
        """Off the UI thread — SMTP can sit there for the full 30s timeout."""
        try:
            done = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=180, cwd=HERE)
            output = (done.stdout or "") + (done.stderr or "")
            self.results.put((done.returncode, output.strip(), dry_run))
        except subprocess.TimeoutExpired:
            self.results.put((1, "send_csv.py did not finish in 3 minutes.",
                              dry_run))
        except OSError as exc:
            self.results.put((1, f"Could not run send_csv.py — {exc}", dry_run))

    def drain(self):
        """Tkinter is single-threaded, so the worker hands results back here."""
        try:
            while True:
                code, output, dry_run = self.results.get_nowait()
                self.finish(code, output, dry_run)
        except queue.Empty:
            pass
        self.root.after(120, self.drain)

    def finish(self, code, output, dry_run):
        self.running = False
        self.send_btn.state(["!disabled"])
        self.check_btn.state(["!disabled"])

        if code != 0:
            self.status.configure(text="Not sent.", style="Err.TLabel")
            messagebox.showerror("Not sent", output or "send_csv.py failed.",
                                 parent=self.root)
            return

        if dry_run:
            self.status.configure(text="Looks fine — nothing sent yet.",
                                  style="Ok.TLabel")
            messagebox.showinfo("Check", output, parent=self.root)
            return

        self.recent = save_recent(self.to_var.get(), self.recent)
        self.to_box.configure(values=self.recent)
        self.status.configure(
            text=f"Sent {os.path.basename(self.file_var.get())} to "
                 f"{self.to_var.get().strip()}.", style="Ok.TLabel")

    def complain(self, text):
        self.status.configure(text=text.replace("\n", " "), style="Err.TLabel")
        messagebox.showwarning("Check the form", text, parent=self.root)


def main():
    initial = sys.argv[1] if len(sys.argv) > 1 else None
    root = tk.Tk()
    App(root, initial)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
