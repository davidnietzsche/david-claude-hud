#Requires -Version 5.1
<#
  Windows installer for David Claude HUD.

  Mirrors install.sh: build, register for login, add the attention hooks.

  UNTESTED — written without access to a Windows machine. The steps follow
  documented behaviour but none of it has been run. See README.md.
#>
$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
  Write-Error "This installer is for Windows. On macOS run ./install.sh"; exit 1
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here

# --- prerequisites -----------------------------------------------------------
foreach ($tool in @('dotnet', 'python')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    Write-Error "$tool is required and not on PATH."; exit 1
  }
}
# WebView2 ships with Windows 11 and current Windows 10; warn rather than fail,
# since a machine can have the runtime without the registry key being obvious.
$wv = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\*' `
      -ErrorAction SilentlyContinue | Where-Object { $_.pv -and $_.name -match 'WebView2' }
if (-not $wv) {
  Write-Warning "WebView2 runtime not detected. If the window comes up blank, install it from https://developer.microsoft.com/microsoft-edge/webview2/"
}

Write-Host "-> building"
Push-Location $here
dotnet build -c Release | Out-Null
Pop-Location
$exe = Join-Path $here 'bin\Release\net8.0-windows\ClaudeHUD.exe'
if (-not (Test-Path $exe)) { Write-Error "build produced no ClaudeHUD.exe"; exit 1 }

Write-Host "-> registering attention hooks"
python (Join-Path $repo 'hooks\install-hooks.py')

Write-Host "-> starting at login"
# A scheduled task rather than the Startup folder: it survives sign-out and can
# be removed cleanly, which is the closest thing to a LaunchAgent here.
$action  = New-ScheduledTaskAction -Execute $exe
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
             -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName 'ClaudeHUD' -Action $action -Trigger $trigger `
  -Settings $set -Force | Out-Null

Get-Process ClaudeHUD -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process $exe

Write-Host "OK — Claude HUD installed and running."
Write-Host "   uninstall:  Unregister-ScheduledTask -TaskName ClaudeHUD -Confirm:`$false"
