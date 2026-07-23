# Uninstall-Startup.ps1
# Path: Uninstall-Startup.ps1
# Summary: Removes the current Windows user's Chatwork Read All startup shortcut.

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'ChatworkReadAll.ps1'

# Delegate shortcut removal to the main app so the shortcut name remains centralized.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -UninstallStartup
