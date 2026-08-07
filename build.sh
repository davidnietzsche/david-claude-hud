#!/bin/bash
# Build Claude HUD into a self-contained .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeHUD.app"
BIN="$APP/Contents/MacOS/ClaudeHUD"
RES="$APP/Contents/Resources"

echo "→ compiling"
mkdir -p "$APP/Contents/MacOS" "$RES"
clang -fobjc-arc -O2 -Wall \
      -framework Cocoa -framework WebKit -framework Carbon -framework UserNotifications -framework QuartzCore \
      hud.m -o "$BIN"

echo "→ bundling"
cp ui.html collect.py "$RES/"
chmod +x "$RES/collect.py"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Claude HUD</string>
  <key>CFBundleDisplayName</key>       <string>Claude HUD</string>
  <key>CFBundleIdentifier</key>        <string>io.github.davidnietzsche.claudehud</string>
  <key>CFBundleExecutable</key>        <string>ClaudeHUD</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>12.0</string>
  <!-- Accessory app: lives in the menu bar, no Dock icon, never steals focus. -->
  <key>LSUIElement</key>               <true/>
  <!-- Required to drive Terminal.app via AppleScript (click-to-jump). -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Claude HUD brings the Terminal window of a Claude session to the front when you click it.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS keeps a stable identity for the Automation permission
# instead of re-prompting after every rebuild.
echo "→ signing"
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "✓ built $(pwd)/$APP"
