#!/bin/bash
# Install Claude HUD as a login agent so it's always there after a reboot.
set -euo pipefail
cd "$(dirname "$0")"

# Point people at the right installer rather than failing halfway through.
case "$(uname -s)" in
  Darwin) ;;
  *) echo "This installer is for macOS. On Windows run:  windows\\install.ps1" >&2
     echo "(uname reports: $(uname -s))" >&2; exit 1 ;;
esac
DIR="$(pwd)"
LABEL="io.github.davidnietzsche.claudehud"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <!-- Launch through `open` so the app is registered with LaunchServices and
       gets a real GUI session; running the binary directly yields 0x0 windows
       and no menu-bar item. -W keeps this process alive for the app's lifetime
       so KeepAlive still works.

       The pkill first is essential: launchd only owns the `open` wrapper, not
       the app LaunchServices spawns. Without it a restart just re-activates
       the already-running old binary and the new build never loads. The [C]
       class stops pkill -f matching this very command line. -->
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>pkill -f '[C]laudeHUD.app/Contents/MacOS/ClaudeHUD'; sleep 1; exec /usr/bin/open -W -a '$DIR/ClaudeHUD.app'</string>
  </array>
  <key>RunAtLoad</key><true/>
  <!-- Restart on crash, but respect a deliberate quit from the menu. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardErrorPath</key><string>/tmp/claude-hud.log</string>
</dict>
</plist>
PLISTEOF

# [C] class again: without it this matches (and kills) the shell running it.
echo "→ registering attention hooks"
python3 "$DIR/hooks/install-hooks.py"

# [C] class again: without it this matches (and kills) the shell running it.
pkill -f '[C]laudeHUD.app/Contents/MacOS' 2>/dev/null || true
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

# bootstrap races the bootout and fails with EIO if the old job hasn't fully
# unloaded yet — retry rather than leaving the agent unloaded.
for i in 1 2 3 4 5; do
  sleep 1
  if launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then break; fi
  [ "$i" = 5 ] && { echo "✗ bootstrap failed after 5 tries"; exit 1; }
done

echo "✓ installed — Claude HUD now starts at login"
echo "  uninstall:  launchctl bootout gui/$UID/$LABEL && rm $PLIST"
