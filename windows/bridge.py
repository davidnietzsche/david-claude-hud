#!/usr/bin/env python3
"""Local bridge between the HUD page and the machine, for the PowerShell build.

On macOS the page lives inside a WKWebView and talks to the native shell over a
message handler. There is no equivalent here without compiling something, so
the page is served to Edge in app mode and talks back over HTTP on loopback
instead. The interface and the collector are the same files either way — only
the transport differs.

Standard library only: it has to run on a stock Windows box with nothing
installed but Python, which is already there for the collector.
"""

import json
import os
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # ui.html and collect.py live one up
IS_WINDOWS = os.name == "nt"

# Anything on the machine can reach a loopback port, so every request carries a
# token minted at startup and handed to the page in its URL. Without it the
# command endpoint would let any local page kill processes.
TOKEN = secrets.token_urlsafe(16)


def collect():
    """One tick of the shared collector."""
    try:
        p = subprocess.run([sys.executable, os.path.join(ROOT, "collect.py")],
                           capture_output=True, text=True, timeout=20,
                           creationflags=(0x08000000 if IS_WINDOWS else 0))
        return json.loads(p.stdout) if p.stdout.strip() else None
    except Exception:
        return None


def machine():
    """CPU and RAM for the meters the collector doesn't own.

    Thermal state is deliberately absent — the collector already declares
    temp: false on Windows, so the page hides that meter rather than showing a
    number nothing can produce."""
    if not IS_WINDOWS:
        return {"cpu": 0.0, "ram": 0.0, "therm": 0, "batt": -1}
    sys.path.insert(0, ROOT)
    try:
        import platform_win as win
        cpu = win.cpu_percent() or 0.0
        ram, _ = win.parse_memory(win.ps1(win.PS_MEMORY))
    except Exception:
        cpu, ram = 0.0, 0.0
    return {"cpu": cpu, "ram": ram or 0.0, "therm": 0, "batt": -1}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass                              # a console window is not a log

    def _authed(self):
        q = urlparse(self.path).query
        return TOKEN in q or self.headers.get("X-Hud-Token") == TOKEN

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass                          # the window was closed mid-response

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            with open(os.path.join(ROOT, "ui.html"), "rb") as f:
                page = f.read()
            # Hand the page its token so its fetches are authenticated.
            page = page.replace(b"<script>",
                                b'<script>window.__hudToken="' +
                                TOKEN.encode() + b'";</script><script>', 1)
            return self._send(200, page, "text/html; charset=utf-8")

        if path == "/data":
            if not self._authed():
                return self._send(403, b'{"error":"forbidden"}')
            d = collect() or {}
            d["machine"] = machine()
            return self._send(200, json.dumps(d))

        if path.startswith("/sounds/"):
            f = os.path.join(ROOT, "sounds", os.path.basename(path))
            if os.path.isfile(f):
                with open(f, "rb") as fh:
                    return self._send(200, fh.read(), "audio/wav")

        self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        if urlparse(self.path).path != "/cmd" or not self._authed():
            return self._send(403, b'{"error":"forbidden"}')
        try:
            n = int(self.headers.get("Content-Length") or 0)
            msg = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, b'{"error":"bad json"}')
        self._send(200, json.dumps(handle(msg)))


# ---------------------------------------------------------------- commands

def handle(msg):
    """The same command vocabulary the macOS shell answers, minus the ones
    Windows can't honour — which the page already knows not to send, because
    the collector reports jumpToTerminal: false there."""
    cmd = msg.get("cmd")

    if cmd == "sound":
        play(msg.get("which"))
    elif cmd == "quit":
        threading.Timer(0.2, lambda: os._exit(0)).start()
    elif cmd == "killPid":
        signal_pid(msg.get("pid"), force=True)
    elif cmd == "quitApp":
        signal_pid(msg.get("pid"), force=False)
    elif cmd in ("geometry", "dock", "drag", "dragEnd", "theme", "badge",
                 "notify", "pin", "rename", "focus", "job"):
        return window_cmd(cmd, msg)
    return {"ok": True}


def play(which):
    name = "done" if which == "done" else "needs-you"
    path = os.path.join(ROOT, "sounds", name + ".wav")
    if IS_WINDOWS:
        try:
            import winsound
            winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)
            return
        except Exception:
            pass
    else:
        subprocess.Popen(["afplay", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def signal_pid(pid, force):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return
    if pid <= 4:
        return                            # never the kernel or System
    if IS_WINDOWS:
        # /T takes the children with it; a browser leaves helpers behind
        # otherwise. Without /F this is a polite close request.
        args = ["taskkill", "/PID", str(pid), "/T"] + (["/F"] if force else [])
        subprocess.run(args, capture_output=True,
                       creationflags=0x08000000)
    else:
        os.kill(pid, 9 if force else 15)


# --- window control -----------------------------------------------------------
# Edge owns the window, so moving and pinning it is done from PowerShell via
# SetWindowPos. Requests are written to a file the watcher script polls, which
# keeps this process free of any Windows-only imports.

WINCMD = os.path.join(os.path.expanduser("~"), ".claude-hud", "wincmd.json")


def window_cmd(cmd, msg):
    if not IS_WINDOWS:
        return {"ok": True, "ignored": cmd}
    try:
        os.makedirs(os.path.dirname(WINCMD), exist_ok=True)
        with open(WINCMD, "w") as f:
            json.dump({"cmd": cmd, "msg": msg, "at": time.time()}, f)
    except Exception:
        pass
    return {"ok": True}


def main():
    port = int(os.environ.get("HUD_PORT") or 0)
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    actual = srv.server_address[1]
    # run.ps1 reads this line to know where to point Edge.
    print(json.dumps({"port": actual, "token": TOKEN}), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
