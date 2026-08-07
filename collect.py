#!/usr/bin/env python3
"""
Claude HUD data collector.

Emits one JSON blob on stdout describing:
  - live Claude Code sessions (name, status, tty, cpu, how long since it changed)
  - Anthropic usage limits (5-hour session window + weekly)
  - background jobs (launchd agents + crontab entries)

Everything slow (network, AppleScript) is cached on disk and refreshed by a
detached child process, so the fast path never blocks the HUD's 1.5s tick.
"""

import json
import os
import re
import subprocess
import sys
import time
import glob
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
HUD_DIR = os.path.join(HOME, ".claude-hud")
SESS_DIR = os.path.join(HOME, ".claude", "sessions")
LA_DIR = os.path.join(HOME, "Library", "LaunchAgents")

STATE_F = os.path.join(HUD_DIR, "state.json")
ATTN_DIR = os.path.join(HUD_DIR, "attention")
USAGE_F = os.path.join(HUD_DIR, "usage.json")

USAGE_TTL = 300     # usage moves slowly; polling harder just earns a 429
USAGE_ERR_TTL = 600 # after an error (esp. rate limiting), back well off
DONE_WINDOW = 600   # keep "just finished" highlighted for 10 min

# Job labels we care about: anything that isn't vendor noise.
LABEL_SKIP = ("com.apple.", "com.google.", "com.DigiDNA", "com.microsoft.",
              "com.adobe.", "com.docker.", "com.zerotier", "homebrew.")


# ---------------------------------------------------------------- utilities

def _read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def _write_json(path, obj):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:
        pass


def _run(cmd, timeout=10):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout
    except Exception:
        return ""


def _fresh(path, ttl):
    try:
        return (time.time() - os.path.getmtime(path)) < ttl
    except OSError:
        return False


def _spawn_refresh(what):
    """Kick off a detached refresh so this tick can return immediately.

    Guarded by a lock file: without it, every 1.5s tick would spawn another
    refresh while the previous one is still in flight, which is what got the
    usage endpoint to start answering 429."""
    lock = os.path.join(HUD_DIR, what + ".lock")
    try:
        if os.path.exists(lock) and (time.time() - os.path.getmtime(lock)) < 60:
            return
        open(lock, "w").close()
    except OSError:
        pass
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--refresh", what],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
    except Exception:
        pass


def _clear_lock(what):
    try:
        os.remove(os.path.join(HUD_DIR, what + ".lock"))
    except OSError:
        pass


# ---------------------------------------------------------------- sessions

def ps_snapshot():
    """pid -> {ppid, tty, cpu, rss, etime, comm} for every process,
    plus a ppid -> [pid] child index."""
    out = _run(["ps", "-Ao", "pid=,ppid=,tty=,%cpu=,rss=,etime=,comm="])
    snap, kids = {}, {}
    for line in out.splitlines():
        parts = line.split(None, 6)
        if len(parts) < 7:
            continue
        pid, ppid, tty, cpu, rss, etime, comm = parts
        try:
            pid, ppid = int(pid), int(ppid)
            snap[pid] = {"ppid": ppid, "tty": tty, "cpu": float(cpu),
                         "rss": int(rss) * 1024, "etime": etime, "comm": comm}
        except ValueError:
            continue
        kids.setdefault(ppid, []).append(pid)
    return snap, kids


def tree_usage(root, snap, kids):
    """Total RSS and CPU for a process and everything it spawned — a Claude
    session is really the CLI plus its node/python/MCP children, and the
    children are where most of the memory actually goes."""
    rss = cpu = 0
    stack, seen = [root], set()
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        p = snap.get(pid)
        if not p:
            continue
        rss += p["rss"]
        cpu += p["cpu"]
        stack.extend(kids.get(pid, ()))
    return rss, cpu


def read_attention():
    """Sessions Claude Code has asked for a human about, dropped by the
    Notification hook. Keyed by session id."""
    out = {}
    try:
        names = os.listdir(ATTN_DIR)
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        d = _read_json(os.path.join(ATTN_DIR, n))
        if d and d.get("sessionId"):
            out[d["sessionId"]] = d
    return out


def collect_sessions(now_ms):
    snap, kids = ps_snapshot()
    attn = read_attention()
    live_sids = set()

    prev = _read_json(STATE_F, {}) or {}
    state = {}
    sessions = []

    for path in glob.glob(os.path.join(SESS_DIR, "*.json")):
        d = _read_json(path)
        if not d:
            continue
        pid = d.get("pid")
        proc = snap.get(pid)
        # Drop stale files whose process is gone, or whose PID got recycled
        # into something that isn't Claude.
        if not proc or "claude" not in proc["comm"].lower():
            continue

        sid = d.get("sessionId") or str(pid)
        status = d.get("status") or "idle"
        changed = d.get("statusUpdatedAt") or d.get("updatedAt") or now_ms

        old = prev.get(sid, {})
        finished_at = old.get("finishedAt")
        # busy -> idle is the moment David actually cares about.
        if old.get("status") == "busy" and status != "busy":
            finished_at = now_ms
        elif status == "busy":
            finished_at = None

        state[sid] = {"status": status, "finishedAt": finished_at}

        wait = attn.get(sid)
        if wait:
            bucket = "waiting"
        elif status == "busy":
            bucket = "busy"
        elif finished_at and (now_ms - finished_at) < DONE_WINDOW * 1000:
            bucket = "done"
        else:
            bucket = "idle"

        tty_short = proc["tty"] if proc["tty"] != "??" else ""
        rss, cpu = tree_usage(pid, snap, kids)
        live_sids.add(sid)
        sessions.append({
            "waitingAt": wait.get("at") if wait else None,
            "waitMsg": (wait.get("message") or "") if wait else "",
            "mem": rss,
            "treeCpu": round(cpu, 1),
            "pid": pid,
            "sid": sid,
            "name": d.get("name") or f"pid {pid}",
            "cwd": d.get("cwd") or "",
            "status": bucket,
            "raw_status": status,
            "tty": tty_short,
            "devtty": "/dev/" + tty_short if tty_short else "",
            "cpu": proc["cpu"],
            "uptime": proc["etime"],
            "idleFor": max(0, (now_ms - changed) // 1000),
            # finishedAt is emitted even after the "done" highlight expires, so
            # the UI can keep an unread marker until it's actually acknowledged.
            "finishedAt": finished_at,
            "finishedFor": (now_ms - finished_at) // 1000 if finished_at else None,
        })

    _write_json(STATE_F, state)

    # Drop markers whose session has gone away, so they can't wedge forever.
    try:
        for n in os.listdir(ATTN_DIR):
            if n.endswith(".json") and n[:-5] not in live_sids:
                os.remove(os.path.join(ATTN_DIR, n))
    except OSError:
        pass

    rank = {"waiting": 0, "busy": 1, "done": 2, "idle": 3}
    sessions.sort(key=lambda s: (rank[s["status"]], s["idleFor"]))
    return sessions


# ---------------------------------------------------------------- usage

def refresh_usage():
    """Ask the OAuth endpoint for limit utilisation. Token is read fresh from
    the keychain every time so Claude Code's own refresh is picked up.

    A failure never discards the last good numbers — it just annotates them,
    so a transient 429 doesn't blank out the meters."""
    prev = _read_json(USAGE_F, {}) or {}

    def fail(msg):
        prev["error"] = msg
        prev["errorAt"] = int(time.time() * 1000)
        _write_json(USAGE_F, prev)
        _clear_lock("usage")

    raw = _run(["security", "find-generic-password",
                "-s", "Claude Code-credentials", "-w"], timeout=10)
    try:
        token = json.loads(raw)["claudeAiOauth"]["accessToken"]
    except Exception:
        return fail("no token")

    out = _run(["curl", "-s", "-m", "20",
                "https://api.anthropic.com/api/oauth/usage",
                "-H", f"Authorization: Bearer {token}",
                "-H", "anthropic-beta: oauth-2025-04-20"], timeout=25)
    try:
        d = json.loads(out)
    except Exception:
        return fail("offline")
    if not isinstance(d, dict) or "five_hour" not in d:
        err = d.get("error") if isinstance(d, dict) else None
        kind = (err or {}).get("type", "") if isinstance(err, dict) else ""
        return fail("rate limited" if "rate_limit" in kind else "auth error")

    def pack(node):
        if not isinstance(node, dict):
            return None
        return {"pct": node.get("utilization"), "resets": node.get("resets_at")}

    # The scoped weekly limit (per-model) often bites before the overall one.
    scoped = None
    for lim in d.get("limits") or []:
        if lim.get("kind") == "weekly_scoped":
            model = ((lim.get("scope") or {}).get("model") or {})
            scoped = {"pct": lim.get("percent"), "resets": lim.get("resets_at"),
                      "label": model.get("display_name") or "scoped"}
            break

    extra = d.get("extra_usage") or {}
    _write_json(USAGE_F, {
        "session": pack(d.get("five_hour")),
        "weekly": pack(d.get("seven_day")),
        "scoped": scoped,
        "extraEnabled": bool(extra.get("is_enabled")),
        "fetchedAt": int(time.time() * 1000),
    })
    _clear_lock("usage")


def collect_usage():
    cur = _read_json(USAGE_F, {}) or {}
    # Back off hard after an error so a rate limit doesn't feed itself.
    ttl = USAGE_ERR_TTL if cur.get("error") else USAGE_TTL
    if not _fresh(USAGE_F, ttl):
        _spawn_refresh("usage")
    return cur or {"error": "loading"}


# ---------------------------------------------------------------- jobs

def _next_calendar(spec_list, now):
    """Next fire time for a launchd StartCalendarInterval (dict or list)."""
    if isinstance(spec_list, dict):
        spec_list = [spec_list]
    best = None
    for spec in spec_list or []:
        if not isinstance(spec, dict):
            continue
        minute = spec.get("Minute")
        hour = spec.get("Hour")
        wd = spec.get("Weekday")
        day = spec.get("Day")
        # Walk forward minute-by-minute is too slow; step candidate times.
        cand = now.replace(second=0, microsecond=0)
        for _ in range(60 * 24 * 8):  # up to 8 days out
            cand += timedelta(minutes=1)
            if minute is not None and cand.minute != minute:
                continue
            if hour is not None and cand.hour != hour:
                continue
            if day is not None and cand.day != day:
                continue
            if wd is not None and (cand.weekday() + 1) % 7 != wd % 7:
                continue
            break
        else:
            continue
        if best is None or cand < best:
            best = cand
    return best


def _cron_field_match(field, value, lo, hi):
    if field == "*":
        return True
    for part in field.split(","):
        if part.startswith("*/"):
            try:
                if (value - lo) % int(part[2:]) == 0:
                    return True
            except ValueError:
                pass
            continue
        if "-" in part:
            try:
                a, b = part.split("-", 1)
                step = 1
                if "/" in b:
                    b, s = b.split("/", 1)
                    step = int(s)
                a, b = int(a), int(b)
                if a <= value <= b and (value - a) % step == 0:
                    return True
            except ValueError:
                pass
            continue
        try:
            if int(part) == value:
                return True
        except ValueError:
            pass
    return False


def _next_cron(mi, ho, dom, mon, dow, now):
    cand = now.replace(second=0, microsecond=0)
    for _ in range(60 * 24 * 8):
        cand += timedelta(minutes=1)
        if not _cron_field_match(mi, cand.minute, 0, 59):
            continue
        if not _cron_field_match(ho, cand.hour, 0, 23):
            continue
        if not _cron_field_match(mon, cand.month, 1, 12):
            continue
        dom_star, dow_star = dom == "*", dow == "*"
        dom_ok = _cron_field_match(dom, cand.day, 1, 31)
        dow_ok = _cron_field_match(dow, cand.weekday() + 1 if cand.weekday() < 6 else 0, 0, 6)
        # cron semantics: if both restricted, either matching fires it
        if dom_star and dow_star:
            pass
        elif dom_star:
            if not dow_ok:
                continue
        elif dow_star:
            if not dom_ok:
                continue
        elif not (dom_ok or dow_ok):
            continue
        return cand
    return None


def collect_launchd(now):
    out = _run(["launchctl", "list"], timeout=8)
    jobs = []
    for line in out.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        pid_s, status_s, label = parts[0], parts[1], parts[2].strip()
        if any(label.startswith(p) for p in LABEL_SKIP):
            continue
        if label.startswith("application.") or label.startswith("0x"):
            continue

        running = pid_s not in ("-", "")
        try:
            last = int(status_s)
        except ValueError:
            last = 0

        plist = os.path.join(LA_DIR, label + ".plist")
        sched, nxt = "", None
        if os.path.exists(plist):
            txt = _run(["plutil", "-convert", "json", "-o", "-", plist], timeout=5)
            p = None
            try:
                p = json.loads(txt)
            except Exception:
                p = None
            if isinstance(p, dict):
                if "StartInterval" in p:
                    iv = p["StartInterval"]
                    sched = f"every {iv//60}m" if iv >= 60 else f"every {iv}s"
                elif "StartCalendarInterval" in p:
                    nxt = _next_calendar(p["StartCalendarInterval"], now)
                    if nxt:
                        sched = nxt.strftime("%H:%M")
                elif p.get("KeepAlive"):
                    sched = "always on"
                elif p.get("RunAtLoad"):
                    sched = "at login"

        # com.acme.backup.nightly -> backup.nightly  (drop the reverse-DNS prefix)
        bits = label.split(".")
        short = ".".join(bits[2:]) if len(bits) >= 3 else label

        jobs.append({
            "kind": "launchd",
            "label": label,
            "name": short,
            "running": running,
            "pid": pid_s if running else "",
            "exit": last,
            "failed": last != 0 and not running,
            "sched": sched,
            "nextTs": int(nxt.timestamp() * 1000) if nxt else None,
        })
    return jobs


def collect_cron(now):
    out = _run(["crontab", "-l"], timeout=6)
    jobs = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        mi, ho, dom, mon, dow, cmd = parts
        if not re.match(r"^[\d*/,\-]+$", mi):
            continue  # env assignment or @reboot style, skip
        nxt = _next_cron(mi, ho, dom, mon, dow, now)

        # Human label: the script being run, not the whole shell line.
        m = re.findall(r"([\w\-.]+\.(?:py|sh|js))", cmd)
        name = m[0] if m else cmd.split()[0].split("/")[-1]
        flag = re.search(r"--format\s+(\S+)|--(\w[\w-]*)", cmd)
        if flag:
            name += " " + (flag.group(1) or flag.group(2))

        jobs.append({
            "kind": "cron",
            "label": cmd[:200],
            "name": name,
            "running": False,
            "pid": "",
            "exit": 0,
            "failed": False,
            "sched": f"{ho}:{mi.zfill(2)}" if mi.isdigit() and ho.isdigit()
                     else f"{mi} {ho} {dom} {mon} {dow}",
            "nextTs": int(nxt.timestamp() * 1000) if nxt else None,
        })
    return jobs


# ---------------------------------------------------------------- main

def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--refresh":
        os.makedirs(HUD_DIR, exist_ok=True)
        what = sys.argv[2]
        try:
            if what == "usage":
                refresh_usage()
        finally:
            _clear_lock(what)
        return

    os.makedirs(HUD_DIR, exist_ok=True)
    now = datetime.now()
    now_ms = int(time.time() * 1000)

    sessions = collect_sessions(now_ms)
    jobs = collect_launchd(now) + collect_cron(now)
    jobs.sort(key=lambda j: (not j["running"], not j["failed"],
                             j["nextTs"] or 9e18, j["name"]))

    print(json.dumps({
        "now": now_ms,
        "sessions": sessions,
        "counts": {
            "total": len(sessions),
            "busy": sum(1 for s in sessions if s["status"] == "busy"),
            "done": sum(1 for s in sessions if s["status"] == "done"),
            "waiting": sum(1 for s in sessions if s["status"] == "waiting"),
            # how much of the machine's RAM pressure is your own sessions
            "mem": sum(s["mem"] for s in sessions),
        },
        "usage": collect_usage(),
        "jobs": jobs,
        "jobCounts": {
            "running": sum(1 for j in jobs if j["running"]),
            "failed": sum(1 for j in jobs if j["failed"]),
            "total": len(jobs),
        },
    }))


if __name__ == "__main__":
    main()
