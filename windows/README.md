# Windows shell — untested

The macOS shell is an `NSPanel` hosting a `WKWebView`. This is the same idea in
Win32 terms: a borderless, always-on-top, no-activate tool window hosting
WebView2, running **the identical `ui.html` and `collect.py`**. Only the shell
differs between platforms; the interface and the data layer are shared verbatim,
not forked.

## What has been verified, and how

The Python collector's Windows path was run end to end against a simulated
Windows process table on a Mac. That found five real bugs that would each have
been fatal or near-fatal in production, and they're fixed:

1. **No sessions at all.** Discovery keyed on a process owning a tty. Windows
   processes have none, so the list came back empty — the HUD would have shown
   nothing whatsoever.
2. **Nothing ever matched a provider.** The match list says `claude`; on Windows
   the executable is `claude.exe`, so no process was ever recognised as an agent.
3. **The heat list was always empty.** `main()` took two process snapshots per
   tick. On macOS that merely listed everything twice; on Windows the second
   call computed its CPU delta against a state file written milliseconds earlier
   and every process came back at 0%.
4. **Orphan detection never fired.** Unix reparents an orphan to pid 1; Windows
   leaves the dead parent's id in place.
5. **System processes weren't protected.** The protected-name list carried
   `.exe` suffixes but names are compared with the extension stripped, so `dwm`
   and `svchost` fell through as ordinary processes.

Sessions, host detection, heat attribution, system protection and orphan
detection all pass against the simulation now.

## The shell has never been built or run

It was written on a Mac with no Windows machine and no cross-compiler, so
nothing here has been compiled, let alone used. The Python collector *has* been
tested — its Windows parsers are unit-tested against captured PowerShell output
— but everything in this directory is unverified.

If you're the first person to run it, these are the parts most likely to be
wrong:

1. **`WS_EX_NOACTIVATE`** — meant to stop the HUD stealing focus from your
   terminal, as the non-activating `NSPanel` does on macOS. It may also swallow
   clicks inside WebView2; if the interface is dead to the mouse, that's the
   first thing to drop.
2. **Dragging** — `WM_NCLBUTTONDOWN`/`HTCAPTION` is the usual trick for moving a
   borderless window, but it interacts badly with `NOACTIVATE` in some builds.
3. **Transparent background** — the page paints its own near-opaque background,
   so this may not matter, but rounded corners will need
   `DwmSetWindowAttribute` with `DWMWCP_ROUND` rather than a layer mask.
4. **`python` on PATH** — the collector is launched as `python`. On a machine
   where it's `py` or a full path, that needs changing.

## What Windows can't do

The collector declares its capabilities and the interface hides whatever isn't
supported, so these degrade rather than break:

| | |
|---|---|
| **Temperature** | No equivalent of `NSProcessInfo.thermalState`; consumer Windows exposes no readable die temperature without a vendor driver. The meter is hidden entirely. |
| **Jump to terminal** | macOS addresses a Terminal tab by its tty over AppleScript. Windows Terminal exposes no per-tab addressing at all, so double-click marks a session read instead of pretending to jump. |
| **Rename** | Same reason — there's no tab whose title we could set. |

Everything else — sessions, usage limits, swap, background jobs, abandoned
helpers, the character — works from the shared collector.

## Build

Needs the .NET 8 SDK and the WebView2 runtime (shipped with Windows 11 and
current Windows 10).

```powershell
dotnet build -c Release
```
