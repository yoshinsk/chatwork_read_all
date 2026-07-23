@echo off
rem Uninstall-Startup.cmd
rem Path: Uninstall-Startup.cmd
rem Summary: Removes Chatwork Read All from the current Windows user's Startup folder.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-Startup.ps1"
pause
