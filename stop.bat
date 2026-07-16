@echo off
rem TBH Box - shuts the box down safely (the guest Windows powers off cleanly)
setlocal
cd /d "%~dp0"
echo Shutting the box down (Windows may take up to 2 min to power off)...
docker compose stop
echo Box stopped. To start it again: start.bat
ping -n 6 127.0.0.1 >nul
