@echo off
rem Settings.cmd
rem Path: Settings.cmd
rem Summary: Opens only the Chatwork API token settings dialog.
rem
rem This launcher is for initial setup or API token replacement.
rem It passes -Settings to ChatworkReadAll.ps1, so the application does not call the read-marking PUT API.
rem The settings flow accepts a token, validates it with GET /me, and stores it with Windows DPAPI protection.
rem The script path is resolved from this .cmd file's folder, allowing users to extract the ZIP anywhere.
rem Optional arguments are forwarded after -Settings so maintainers can run checks such as -SelfTest through this launcher.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ChatworkReadAll.ps1" -Settings %*
