#Requires -Version 5.1
<#
  Claude HUD on Windows — no build step.

  Everything the macOS app does with a compiled Cocoa shell is done here with
  what a stock Windows box already has: Edge for the window, PowerShell to pin
  and move it, and Python for the bridge and the collector. The interface
  (ui.html) and the data layer (collect.py) are the same files macOS runs.

  Start it:   .\run.ps1
  Stop it:    close the window, or .\run.ps1 -Stop
#>
[CmdletBinding()]
param(
  [switch]$Stop,
  [int]$Width = 380,
  [int]$Height = 640
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$state = Join-Path $env:USERPROFILE '.claude-hud'
$pidFile = Join-Path $state 'win-pids.json'
New-Item -ItemType Directory -Force -Path $state | Out-Null

# --- Win32 --------------------------------------------------------------------
# SetWindowPos is what makes an ordinary browser window behave like the macOS
# panel: pinned above everything, and movable without touching its contents.
if (-not ('HudNative' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public class HudNative {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(
    IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  public static readonly IntPtr TOPMOST = new IntPtr(-1);
  public const uint NOSIZE = 0x0001, NOMOVE = 0x0002, NOACTIVATE = 0x0010,
                    SHOWWINDOW = 0x0040;
}
'@
}

function Stop-Hud {
  if (Test-Path $pidFile) {
    $p = Get-Content $pidFile -Raw | ConvertFrom-Json
    foreach ($id in @($p.bridge, $p.edge)) {
      if ($id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
  Write-Host "Claude HUD stopped."
}

if ($Stop) { Stop-Hud; return }
Stop-Hud   # never leave a second copy running

# --- prerequisites ------------------------------------------------------------
$python = (Get-Command python -ErrorAction SilentlyContinue) ??
          (Get-Command py -ErrorAction SilentlyContinue)
if (-not $python) { throw "Python is required and not on PATH." }

$edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge not found. It ships with Windows 10 and 11." }

# --- bridge -------------------------------------------------------------------
Write-Host "-> starting bridge"
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $python.Source
$psi.Arguments = "`"$(Join-Path $here 'bridge.py')`""
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$bridge = [Diagnostics.Process]::Start($psi)

# The bridge prints its port and token on the first line, then serves forever.
$line = $bridge.StandardOutput.ReadLine()
if (-not $line) { throw "bridge did not start" }
$info = $line | ConvertFrom-Json
$url = "http://127.0.0.1:$($info.port)/?$($info.token)"
Write-Host "   listening on $($info.port)"

# --- window -------------------------------------------------------------------
# --app= gives a frameless window with no tabs or address bar. A dedicated
# profile directory keeps it out of your normal Edge session, so closing the
# HUD never touches your browsing.
$profile = Join-Path $state 'edge-profile'
$args = @(
  "--app=$url",
  "--user-data-dir=`"$profile`"",
  "--window-size=$Width,$Height",
  "--window-position=40,60",
  "--no-first-run", "--no-default-browser-check",
  "--disable-features=Translate,MediaRouter",
  "--app-shell-host-window-size=$Width`x$Height"
)
Write-Host "-> opening window"
$edgeProc = Start-Process -FilePath $edge -ArgumentList $args -PassThru

@{ bridge = $bridge.Id; edge = $edgeProc.Id } |
  ConvertTo-Json | Set-Content $pidFile

# --- pin on top ---------------------------------------------------------------
# The window handle isn't there the instant Edge starts, so wait for it.
$hwnd = [IntPtr]::Zero
foreach ($i in 1..40) {
  Start-Sleep -Milliseconds 250
  $edgeProc.Refresh()
  if ($edgeProc.MainWindowHandle -ne [IntPtr]::Zero) {
    $hwnd = $edgeProc.MainWindowHandle; break
  }
}
if ($hwnd -eq [IntPtr]::Zero) {
  Write-Warning "Could not find the window to pin it on top; it will still work, just not always-visible."
} else {
  [void][HudNative]::SetWindowPos($hwnd, [HudNative]::TOPMOST, 0, 0, 0, 0,
    [HudNative]::NOMOVE -bor [HudNative]::NOSIZE -bor [HudNative]::NOACTIVATE)
  Write-Host "   pinned on top"
}

# --- window commands ----------------------------------------------------------
# The page can't move its own window from inside a browser, so the bridge writes
# requests to a file and this loop applies them. It also re-pins periodically:
# other applications can steal the topmost slot.
$cmdFile = Join-Path $state 'wincmd.json'
$lastAt = 0
Write-Host "Claude HUD is running. Close the window to quit."
while (-not $edgeProc.HasExited) {
  Start-Sleep -Milliseconds 700
  if ($hwnd -ne [IntPtr]::Zero) {
    [void][HudNative]::SetWindowPos($hwnd, [HudNative]::TOPMOST, 0, 0, 0, 0,
      [HudNative]::NOMOVE -bor [HudNative]::NOSIZE -bor [HudNative]::NOACTIVATE)
  }
  if (-not (Test-Path $cmdFile)) { continue }
  try { $c = Get-Content $cmdFile -Raw | ConvertFrom-Json } catch { continue }
  if (-not $c.at -or $c.at -le $lastAt) { continue }
  $lastAt = $c.at

  switch ($c.cmd) {
    'geometry' {
      if ($hwnd -ne [IntPtr]::Zero -and $c.msg.w -and $c.msg.h) {
        [void][HudNative]::SetWindowPos($hwnd, [HudNative]::TOPMOST, 0, 0,
          [int]$c.msg.w, [int]$c.msg.h,
          [HudNative]::NOMOVE -bor [HudNative]::NOACTIVATE)
      }
    }
    'dock' {
      if ($hwnd -ne [IntPtr]::Zero) {
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $w = if ($c.msg.out) { $Width } else { 40 }
        $x = if ($c.msg.side -eq 'right') {
               if ($c.msg.out) { $wa.Right - $Width - 12 } else { $wa.Right - 36 }
             } else {
               if ($c.msg.out) { $wa.Left + 12 } else { $wa.Left - $Width + 36 }
             }
        [void][HudNative]::SetWindowPos($hwnd, [HudNative]::TOPMOST, $x, 60,
          $w, $Height, [HudNative]::NOACTIVATE)
      }
    }
  }
}

Stop-Hud
