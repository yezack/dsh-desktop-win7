@echo off
rem One-click installer for DSH Desktop on Windows 7.
rem Right-click this file -> "Run as administrator".
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-portable.ps1" %*
echo.
echo ---------------------------------------------------------------
pause
