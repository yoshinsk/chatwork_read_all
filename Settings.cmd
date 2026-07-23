@echo off
rem Settings.cmd
rem Path: Settings.cmd
rem Summary: Opens the Chatwork API token settings dialog.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ChatworkReadAll.ps1" -Settings
