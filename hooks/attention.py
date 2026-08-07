#!/usr/bin/env python3
"""Mark a Claude session as waiting for a human.

Claude Code fires the Notification hook when it wants your attention — a
permission prompt, or a question it can't proceed without. That's the only
reliable signal for "done, waiting for you"; the session status file only
distinguishes busy from idle.

  attention.py set    -> drop a marker for this session
  attention.py clear  -> remove it (the human came back)

Hook payload arrives as JSON on stdin.
"""
import json
import os
import sys
import time

DIR = os.path.expanduser("~/.claude-hud/attention")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "set"
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}

    sid = payload.get("session_id") or ""
    if not sid:
        return
    os.makedirs(DIR, exist_ok=True)
    path = os.path.join(DIR, sid + ".json")

    if mode == "clear":
        try:
            os.remove(path)
        except OSError:
            pass
        return

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({
            "sessionId": sid,
            "at": int(time.time() * 1000),
            "message": (payload.get("message") or "")[:200],
            "cwd": payload.get("cwd") or "",
        }, f)
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
