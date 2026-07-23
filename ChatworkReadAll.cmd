@echo off
rem ChatworkReadAll.cmd
rem Path: ChatworkReadAll.cmd
rem Summary: Launches the Chatwork read-all PowerShell app with a Windows-compatible execution policy.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ChatworkReadAll.ps1" %*
