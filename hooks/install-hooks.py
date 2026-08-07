#!/usr/bin/env python3
"""Register (or remove) the HUD's attention hooks in ~/.claude/settings.json.

The HUD needs to know when a session is *waiting on you* — a permission prompt,
or a question Claude can't proceed past. Claude Code's session file only ever
distinguishes busy from idle, so that signal has to come from the Notification
hook.

This only ever appends its own hook block and leaves every existing hook alone.
A timestamped backup is written before any change.

  install-hooks.py            add the hooks
  install-hooks.py --remove   take them back out
"""

import collections
import json
import os
import shutil
import sys
import time

SETTINGS = os.path.expanduser("~/.claude/settings.json")
ATTENTION = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "attention.py")
MARKER = "attention.py"

# event -> argument passed to attention.py
EVENTS = {
    "Notification": "set",       # Claude wants a human
    "UserPromptSubmit": "clear",  # the human answered
    "Stop": "clear",              # the turn ended
}


def block(mode):
    return {"hooks": [{"type": "command",
                       "command": f"/usr/bin/python3 {ATTENTION} {mode}",
                       "timeout": 5,
                       "async": True}]}


def main():
    remove = "--remove" in sys.argv

    if not os.path.exists(SETTINGS):
        if remove:
            print("no settings.json — nothing to remove")
            return
        os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
        with open(SETTINGS, "w") as f:
            json.dump({}, f)

    with open(SETTINGS) as f:
        data = json.load(f, object_pairs_hook=collections.OrderedDict)

    backup = f"{SETTINGS}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(SETTINGS, backup)

    hooks = data.setdefault("hooks", collections.OrderedDict())
    touched = []

    for event, mode in EVENTS.items():
        arr = hooks.setdefault(event, [])
        mine = [b for b in arr if MARKER in json.dumps(b)]

        if remove:
            if mine:
                hooks[event] = [b for b in arr if MARKER not in json.dumps(b)]
                touched.append(f"-{event}")
            continue

        if mine:
            # Already registered; refresh in case the install path moved.
            hooks[event] = [b for b in arr if MARKER not in json.dumps(b)]
            hooks[event].append(block(mode))
            touched.append(f"~{event}")
        else:
            arr.append(block(mode))
            touched.append(f"+{event}")

    with open(SETTINGS, "w") as f:
        json.dump(data, f, indent=2)

    print("backup:", backup)
    print("hooks:", " ".join(touched) if touched else "(no change)")


if __name__ == "__main__":
    main()
