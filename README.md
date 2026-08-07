# David Claude HUD

A floating always-on-top panel for people running a lot of Claude Code sessions
at once. It answers the question the notification sound can't: **which terminal
just finished, and which one is waiting on me?**

Native macOS accessory app. No Electron, no npm, no external dependencies —
just `clang`, the system `python3`, and Cocoa. The whole thing is four files.

![The HUD](docs/demo-light.png)

## What it shows

**The character** — a pixel companion in the title bar. It dances while any
session is working, rests when nothing is, and waves with a red `!` when
something is blocked on you. The fastest way to read the machine without
reading anything.

**Title bar** — running vs idle counts, plus a `N NEW` badge for sessions that
finished and you haven't opened yet. The badge is mirrored on the menu-bar icon,
so the count is visible even when the panel is hidden or minimised.

**"Just finished" banner** — when a session goes busy → idle, a green banner
names it for 45 seconds. Click it to jump straight to that terminal.

**Meters** — CPU and RAM sampled from `host_statistics64` (instantaneous, not
an average since boot; RAM uses Activity Monitor's app+wired+compressed
definition rather than counting the file cache, which would read ~99% forever).
Below them, your Claude **session** (5-hour) and **weekly** usage windows with
time until reset — the same data `/usage` reports. Hover the weekly bar for the
per-model scoped limit, which is often the one that actually bites first.

**Sessions** — every live Claude Code process: name, state, how long it's been
that way, CPU while busy, and the RAM of its **whole process tree** (the CLI
plus its node/python/MCP children, which is where the memory actually goes).
Click any row to bring that Terminal window to the front and select the right
tab.

A session that's blocked on you sorts to the top in amber and reads
`needs you`.

**Background** — launchd agents and crontab entries. Running jobs green, jobs
that exited non-zero red with their exit code, scheduled jobs with time until
next run. This alone tends to surface a couple of cron jobs that have been
quietly failing for weeks.

<p align="center">
  <img src="docs/demo-dark.png" width="46%" alt="Dark theme">
  <img src="docs/demo-min.png" width="46%" align="top" alt="Minimised">
</p>

## Install

Requires macOS 12+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/davidnietzsche/david-claude-hud.git
cd david-claude-hud
./install.sh
```

That compiles the app, registers a LaunchAgent so it starts at login, and adds
the attention hooks to `~/.claude/settings.json` (appending only — your existing
hooks are left alone, and a timestamped backup is written first).

The first time you click a session row, macOS asks for permission to control
Terminal. Approve it — that's what click-to-jump uses.

**Uninstall**

```sh
launchctl bootout gui/$UID/io.github.davidnietzsche.claudehud
rm ~/Library/LaunchAgents/io.github.davidnietzsche.claudehud.plist
python3 hooks/install-hooks.py --remove
```

## Controls

| | |
|---|---|
| `◐` | light / dark theme |
| `⤢` | compact size |
| `−` | minimise (keeps the session and weekly limit bars) |
| `✕` | quit |
| `⌃⌥H` | show / hide from anywhere |

Drag the panel by any empty area. Position, size, theme and collapsed sections
persist. There's also a `◧` menu-bar item with Show/Hide, Reset Position, Test
Notification, Reload and Quit.

## Alerts

When a session starts waiting on you, the panel un-minimises itself, pulses a
red border, plays a sound, and the character waves. **None of that needs a
permission**, which matters — macOS notification authorisation is easy to end up
denied without noticing.

A desktop notification naming the session is also attempted, and clicking the
banner jumps to that terminal. If banners never appear, check
System Settings → Notifications → Claude HUD: both "Allow notifications" and an
alert style other than None are required. `~/.claude-hud/hud.log` records what
the app tried.

## How it works

- `hud.m` — the native shell. An `NSPanel` at `NSStatusWindowLevel` with
  `CanJoinAllSpaces`, borderless and **non-activating**, so clicking the HUD
  never pulls focus off the terminal you're watching. Hosts a `WKWebView` and
  samples CPU/RAM itself.
- `ui.html` — the interface, over a small message bridge (`drag`, `focus`,
  `geometry`, `theme`, `badge`, `notify`, `sound`, `quit`).
- `collect.py` — emits one JSON blob per 1.5s tick. The usage API is cached on
  disk and refreshed by a detached child under a lock, so the tick never blocks
  on the network and never stacks requests into a rate limit.
- `hooks/attention.py` — marks a session as waiting for a human.

State lives in `~/.claude-hud/`.

**Session state is read straight from `~/.claude/sessions/<pid>.json`**, which
Claude Code maintains itself — nothing to keep in sync. Files whose process has
died, or whose PID got recycled into something that isn't Claude, are filtered
out.

**Usage limits** come from the same OAuth endpoint `/usage` uses. The token is
re-read from your keychain on every refresh, so Claude Code's own token rotation
is picked up automatically. It is never stored anywhere by this app.

**"Waiting for a human"** can't come from the session file — `status` only ever
holds `busy` or `idle`. It hangs off Claude Code's `Notification` hook, the
event that fires when Claude wants your attention; `UserPromptSubmit` and `Stop`
clear it.

## Notes for anyone hacking on this

Things that cost real time to work out:

- **The launchd job must `pkill` the app before re-opening it.** launchd only
  owns the `open -W` wrapper; LaunchServices keeps the app itself alive, so
  `open -a` just re-activates the *old* binary and your new build never loads.
  Verify a restart with process start time > binary mtime — never by how the
  window looks.
- `pkill -f "ClaudeHUD.app/Contents/MacOS"` kills the shell running it, because
  the pattern appears in that shell's own command line. Use a `[C]laudeHUD`
  character class.
- **No `NSVisualEffectView`.** Its material composites through the window
  server, where `layer.cornerRadius` can't reach, so it draws a square frame
  outside your rounded corners. `WKWebView` has the same problem one level down
  — its remote layer tree ignores the parent's `masksToBounds`, so round its
  layer too.
- **Vibrant appearances blend an effect view's subviews into the backdrop**,
  ghosting hosted web content until it's unreadable. Use Aqua/DarkAqua and let
  the page paint its own background.
- AppleScript's `repeat with w in windows` yields **index-based** references.
  Raising a window mid-loop reshuffles every index, so later references point
  somewhere else. Locate first, then act on the window by `id`.
- `activate` raises whatever is frontmost on the **current Space**, undoing a
  raise done just before it. Activate first, then raise, then verify and retry.
- `launchctl bootstrap` races `bootout` and fails with EIO — retry it.
- `NSLog` from an ad-hoc-signed accessory app doesn't reliably reach the unified
  log, and launchd only owns the wrapper so stderr goes nowhere. Hence the
  app's own log file.

## Licence

MIT — see [LICENSE](LICENSE).
