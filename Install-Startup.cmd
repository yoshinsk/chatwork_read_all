@echo off
rem Install-Startup.cmd
rem Path: Install-Startup.cmd
rem Summary: Registers Chatwork Read All to run when the current Windows user signs in.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Startup.ps1"
pause
