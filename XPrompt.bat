@echo off
chcp 65001 >nul
title XPrompt
cd /d "%~dp0"

:loop
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0updater.ps1"
if errorlevel 7 goto loop

echo.
echo XPrompt ostanovlen. Mozhno zakryvat okno.
pause >nul
