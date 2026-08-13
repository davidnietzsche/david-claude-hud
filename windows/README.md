# Windows — optimised for PowerShell

**No build step. Nothing to install.** Everything the macOS app does with a
compiled Cocoa shell is done here with what a stock Windows box already has:
Edge for the window, PowerShell to pin and move it, Python for the bridge and
the collector.

```powershell
git clone https://github.com/davidnietzsche/david-claude-hud.git
cd david-claude-hud\windows
.\run.ps1
```

Stop it by closing the window, or `.\run.ps1 -Stop`.

## Why PowerShell rather than a compiled app

The obvious port is a C# app hosting WebView2. It's still here as an option
(see below), but it needs the .NET SDK, the WebView2 runtime, and a build — and
on Windows, PowerShell is the thing that's *always* already there.

Removing the build step also removed the biggest risk in this port. The C#
shell was ~400 lines that had never been compiled, let alone run. The PowerShell
route replaces it with a Python bridge that has been **tested end to end** and
about 30 lines of `SetWindowPos`, which is the only genuinely Windows-specific
code left.

## How it fits together

| | macOS | Windows |
|---|---|---|
| Interface | `ui.html` | **the same `ui.html`** |
| Data | `collect.py` | **the same `collect.py`** |
| Window | `NSPanel` | Edge in `--app` mode |
| Always on top | `NSStatusWindowLevel` | `SetWindowPos(HWND_TOPMOST)` from PowerShell |
| Page ↔ machine | WKWebView message handler | `bridge.py` on loopback |
| Sound | `NSSound` | `winsound` (standard library) |

The page detects which host it's in and picks its transport, so there is one
interface file, not two. The bridge listens only on `127.0.0.1` and every
request carries a token minted at startup — otherwise any local page could ask
it to kill processes.

## What Windows can't do

The collector declares its capabilities and the interface hides what's missing,
so these degrade rather than break:

| | |
|---|---|
| **Temperature** | No equivalent of `NSProcessInfo.thermalState`, and consumer Windows exposes no readable die temperature without a vendor driver. The meter is absent, not blank. |
| **Jump to a terminal tab** | macOS addresses a Terminal tab by tty over AppleScript. Windows Terminal exposes no per-tab addressing, so double-click marks a session read instead of pretending. |
| **Rename** | Same reason — no tab whose title we could set. |

Rounded corners and translucency are also gone: an Edge app window doesn't do
either. Everything else — sessions, hosts, usage limits, swap, background jobs,
abandoned helpers, the character, the alerts — works from the shared code.

## What's verified, and what isn't

**Tested on macOS, end to end:** the bridge (page served with its token, `/data`
returning a real collector payload, `/cmd` accepting commands, unauthenticated
requests refused with 403), and the page falling back to `fetch` when no
WKWebView is present.

**Tested against a simulated Windows process table:** session discovery, host
detection, heat attribution, system-process protection, orphan detection. That
simulation found five bugs that each made the port non-functional — see the
v2.1.1 release notes.

**Not tested:** `run.ps1` itself. There was no Windows machine here. It's short
and every call in it is documented behaviour, but nobody has run it. If it
fails, the likely spots are Edge's path, how long the window handle takes to
appear, and whether `--app` honours the requested size on your build.

## The C# option

`HudShell.cs` builds a WebView2 app with real rounded corners and a proper tray
icon. It needs the .NET 8 SDK and has never been compiled. Prefer `run.ps1`
unless you specifically want the native window.

```powershell
dotnet build -c Release
```
