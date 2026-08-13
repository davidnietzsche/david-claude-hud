#!/usr/bin/env python3
"""Windows implementations of the handful of things the collector needs from
the operating system.

macOS gets these from ps / vm_stat / sysctl / launchctl; none of those exist
here. Everything below goes through PowerShell and asks for JSON, because
parsing PowerShell's human-readable tables is a losing game — column widths
shift with content and localised builds translate the headers.

Nothing in this file is macOS-specific, and nothing in the macOS path imports
it, so the two can't break each other.
"""

import json
import os
import re
import subprocess
import time

CREATE_NO_WINDOW = 0x08000000   # keep PowerShell from flashing a console


def ps1(script, timeout=20):
    """Run PowerShell and parse its JSON output.

    -NoProfile matters: a user profile that prints anything corrupts the JSON.
    A single object comes back unwrapped, so always hand back a list."""
    try:
        p = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive",
             "-ExecutionPolicy", "Bypass", "-Command", script],
            capture_output=True, text=True, timeout=timeout,
            creationflags=CREATE_NO_WINDOW)
    except Exception:
        return []
    out = (p.stdout or "").strip()
    if not out:
        return []
    try:
        d = json.loads(out)
    except Exception:
        return []
    return d if isinstance(d, list) else [d]


# ---------------------------------------------------------------- processes

PS_SNAPSHOT = r"""
$cpu = @{}
Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
  $cpu[$_.Id] = $(if ($_.CPU) { $_.CPU } else { 0 })
}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
  [PSCustomObject]@{
    pid  = $_.ProcessId
    ppid = $_.ParentProcessId
    rss  = $_.WorkingSetSize
    cpu  = $cpu[[int]$_.ProcessId]
    comm = $(if ($_.ExecutablePath) { $_.ExecutablePath } else { $_.Name })
    cmd  = $_.CommandLine
    started = $(if ($_.CreationDate) { $_.CreationDate.ToString('o') } else { '' })
  }
} | ConvertTo-Json -Compress -Depth 2
"""


def parse_snapshot(rows, now=None):
    """Rows from PS_SNAPSHOT -> the same shape the macOS ps parser produces.

    `cpu` from Get-Process is cumulative seconds, which is what the caller
    wants for its own delta maths — the same thing `ps -o time` gives on macOS.
    Windows has no controlling terminal, so `tty` is always empty; callers use
    that only to tell an interactive session from a daemon, and on Windows that
    distinction comes from having a console window instead."""
    now = now or time.time()
    snap, kids = {}, {}
    for r in rows:
        try:
            pid = int(r["pid"])
            ppid = int(r.get("ppid") or 0)
        except (KeyError, TypeError, ValueError):
            continue
        started = r.get("started") or ""
        try:
            # ISO 8601 with offset; keep it simple rather than pulling in tz libs
            t = time.mktime(time.strptime(started[:19], "%Y-%m-%dT%H:%M:%S"))
            uptime = max(0, int(now - t))
        except (ValueError, TypeError):
            uptime = 0
        snap[pid] = {
            "pid": pid,
            "ppid": ppid,
            "tty": "",
            "cpu": 0.0,                       # filled in by the delta pass
            "cpusec": float(r.get("cpu") or 0),
            "rss": int(r.get("rss") or 0),
            "etime": fmt_uptime(uptime),
            "comm": r.get("comm") or "",
            "cmd": r.get("cmd") or "",
        }
        kids.setdefault(ppid, []).append(pid)
    return snap, kids


def fmt_uptime(secs):
    """Match the shape of ps's ETIME so the UI formats both the same."""
    d, rem = divmod(int(secs), 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    if d:
        return f"{d}-{h:02d}:{m:02d}:{s:02d}"
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


CPU_STATE = os.path.join(os.path.expanduser("~"), ".claude-hud", "wincpu.json")


def snapshot():
    """Snapshot with an instantaneous CPU figure per process.

    Windows only reports cumulative CPU seconds. macOS's ps hands out a decaying
    average directly, and the collector's heat attribution relies on it — left
    at zero, every process looks idle and the "what's making this hot" list
    comes back empty. So the delta is computed here, against the previous tick."""
    snap, kids = parse_snapshot(ps1(PS_SNAPSHOT))
    now = time.time()
    prev = {}
    try:
        with open(CPU_STATE) as f:
            prev = json.load(f)
    except Exception:
        prev = {}

    dt = now - float(prev.get("at") or 0)
    old = prev.get("cpu") or {}
    if 0.2 < dt < 60:
        for pid, p in snap.items():
            was = old.get(str(pid))
            if was is None:
                continue
            used = p["cpusec"] - float(was)
            if used > 0:
                p["cpu"] = round(min(used / dt * 100.0, 100.0 * (os.cpu_count() or 8)), 1)

    try:
        os.makedirs(os.path.dirname(CPU_STATE), exist_ok=True)
        with open(CPU_STATE, "w") as f:
            json.dump({"at": now,
                       "cpu": {str(k): v["cpusec"] for k, v in snap.items()}}, f)
    except Exception:
        pass
    return snap, kids


# ---------------------------------------------------------------- memory

PS_MEMORY = r"""
$os = Get-CimInstance Win32_OperatingSystem
$pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue |
      Measure-Object -Property AllocatedBaseSize,CurrentUsage -Sum
[PSCustomObject]@{
  totalKB = $os.TotalVisibleMemorySize
  freeKB  = $os.FreePhysicalMemory
  pfTotalMB = ($pf | Where-Object Property -eq 'AllocatedBaseSize').Sum
  pfUsedMB  = ($pf | Where-Object Property -eq 'CurrentUsage').Sum
  pagesPerSec = (Get-Counter '\Memory\Pages/sec' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
} | ConvertTo-Json -Compress
"""


def parse_memory(rows):
    """-> (ram_percent_used, swap dict) in the shapes the collector expects.

    Windows reports paging as pages/sec straight from a performance counter,
    so unlike macOS there's no delta to compute here — but the units have to
    match, hence the conversion to MB/s at a 4KB page."""
    if not rows:
        return None, None
    r = rows[0]
    try:
        total = float(r.get("totalKB") or 0)
        free = float(r.get("freeKB") or 0)
    except (TypeError, ValueError):
        return None, None
    ram = round((total - free) / total * 100, 1) if total else None

    used = float(r.get("pfUsedMB") or 0)
    cap = float(r.get("pfTotalMB") or 0)
    pps = r.get("pagesPerSec")
    rate = round(float(pps) * 4096 / 1e6, 1) if pps not in (None, "") else None
    swap = {"usedMB": round(used), "totalMB": round(cap),
            "pct": round(used / cap * 100, 1) if cap else 0,
            "rate": rate}
    return ram, swap


# ---------------------------------------------------------------- cpu

PS_CPU = r"""
[PSCustomObject]@{
  load = (Get-CimInstance Win32_Processor |
          Measure-Object -Property LoadPercentage -Average).Average
} | ConvertTo-Json -Compress
"""


def cpu_percent():
    rows = ps1(PS_CPU)
    if not rows:
        return None
    try:
        return float(rows[0].get("load"))
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------- jobs

PS_TASKS = r"""
Get-ScheduledTask -ErrorAction SilentlyContinue |
  Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } |
  ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    [PSCustomObject]@{
      name    = $_.TaskName
      path    = $_.TaskPath
      state   = [string]$_.State
      lastRun = $(if ($i.LastRunTime) { $i.LastRunTime.ToString('o') } else { '' })
      nextRun = $(if ($i.NextRunTime) { $i.NextRunTime.ToString('o') } else { '' })
      result  = $i.LastTaskResult
      action  = ($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join '; '
    }
  } | ConvertTo-Json -Compress -Depth 3
"""


def parse_tasks(rows, now_ms=None):
    """Scheduled Tasks -> the same job records the launchd collector emits.

    Windows reports success as 0 like everything else, but also uses 267009
    ("task is currently running") and 267011 ("has not yet run"), which are
    emphatically not failures."""
    now_ms = now_ms or int(time.time() * 1000)
    NOT_FAILURES = {0, 267009, 267011, 267014}
    jobs = []
    for r in rows:
        try:
            result = int(r.get("result") or 0)
        except (TypeError, ValueError):
            result = 0
        running = str(r.get("state") or "").lower() == "running"
        nxt = None
        try:
            nxt = int(time.mktime(time.strptime(
                (r.get("nextRun") or "")[:19], "%Y-%m-%dT%H:%M:%S")) * 1000)
        except (ValueError, TypeError):
            nxt = None
        jobs.append({
            "kind": "task",
            "label": (r.get("path") or "") + (r.get("name") or ""),
            "name": r.get("name") or "",
            "running": running,
            "pid": "",
            "exit": result,
            "failed": result not in NOT_FAILURES and not running,
            "sched": "running" if running else "",
            "nextTs": nxt,
            "cmd": (r.get("action") or "").strip(),
            "logPath": "",
            "lastLog": "",
            "logAge": None,
        })
    jobs.sort(key=lambda j: (not j["running"], not j["failed"],
                             j["nextTs"] or 9e18, j["name"]))
    return jobs


def jobs():
    return parse_tasks(ps1(PS_TASKS, timeout=30))


# ---------------------------------------------------------------- credentials

def oauth_token():
    """macOS keeps this in the Keychain; Windows keeps it in a file next to the
    rest of the config."""
    for name in (".credentials.json", "credentials.json"):
        p = os.path.join(os.path.expanduser("~"), ".claude", name)
        try:
            with open(p) as f:
                d = json.load(f)
            tok = (d.get("claudeAiOauth") or {}).get("accessToken")
            if tok:
                return tok
        except Exception:
            continue
    return None


# ---------------------------------------------------------------- capabilities

def capabilities():
    """What this platform can actually report. The UI hides anything false
    rather than showing a permanently blank meter — there is no readable
    thermal sensor on a typical Windows box, so that row simply isn't there."""
    return {
        "temp": False,      # no equivalent of NSProcessInfo.thermalState
        "swap": True,
        "jobs": True,
        "usage": True,
        "jumpToTerminal": False,   # no tty; see README for why
        "orphans": True,
    }
