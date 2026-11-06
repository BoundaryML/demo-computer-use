@echo off
rem Windows: double-click to start the Computer Use dashboard (http://127.0.0.1:8787) in its own window.
rem Runs independently of any editor or app, so it survives them restarting.
rem Extra arguments go to server.py, e.g. start-server.cmd --provider claude
title computer-use server
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoExit -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
) else (
  powershell -NoExit -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
)
