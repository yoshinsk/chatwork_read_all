# Install-Startup.ps1
# Path: Install-Startup.ps1
# Summary: Registers ChatworkReadAll.ps1 in the current Windows user's Startup folder.

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'ChatworkReadAll.ps1'

# Delegate shortcut creation to the main app so startup behavior stays in one place.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -InstallStartup
