@echo off
rem Double-click to install the Claude Code attention hooks. Pass -Uninstall or -DryRun from a prompt.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
