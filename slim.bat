@echo off
rem Nexo Box - slims an ALREADY-installed box (thin disk + lower RAM/CPU)
rem Preserves Windows and everything installed in it. Interrupts the box for a few minutes.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\slim.ps1"
echo.
pause
