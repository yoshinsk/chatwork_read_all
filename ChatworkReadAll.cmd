@echo off
rem ChatworkReadAll.cmd
rem Path: ChatworkReadAll.cmd
rem Summary: Launches the manual Chatwork read-all PowerShell application.
rem
rem This file is the user-facing launcher for normal execution.
rem It starts ChatworkReadAll.ps1 from the same extracted folder as this .cmd file.
rem -NoProfile keeps user-specific PowerShell profile scripts from changing runtime behavior.
rem -ExecutionPolicy Bypass applies only to this process so users can run the bundled script even when direct .ps1 execution is blocked.
rem Optional command-line arguments are forwarded to the PowerShell script for verification or maintenance use.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ChatworkReadAll.ps1" %*
