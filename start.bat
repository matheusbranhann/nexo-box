@echo off
rem TBH Box - starts the box (and Docker Desktop, if needed) and opens the screen
setlocal
cd /d "%~dp0"

if not exist ".env" (
    echo .env not found - run install.bat first.
    pause
    exit /b 1
)

docker info >nul 2>&1
if not errorlevel 1 goto boxup

if not exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" (
    echo Docker Desktop not found - run install.bat first.
    pause
    exit /b 1
)
echo Starting Docker Desktop...
start "" "%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
echo Waiting for Docker to respond (up to 6 min)...
set /a TRIES=0

:waitdocker
rem ping as a ~5s delay: unlike timeout, it works with redirected stdin (automation/AI)
ping -n 6 127.0.0.1 >nul
docker info >nul 2>&1
if not errorlevel 1 goto boxup
set /a TRIES+=1
if %TRIES% geq 72 (
    echo Docker did not respond within 6 min. Open Docker Desktop manually,
    echo finish the wizard if it is the first run, and run start.bat again.
    pause
    exit /b 1
)
goto waitdocker

:boxup
rem ensures the KVM module in the WSL2 kernel (it is gone after every host wsl --shutdown/reboot)
wsl -d docker-desktop -u root -e sh -c "modprobe kvm_amd 2>/dev/null; modprobe kvm_intel 2>/dev/null; true" >nul 2>&1
docker compose up -d
if errorlevel 1 (
    echo.
    echo Failed to start the box. Run install.bat if this is the first time on this PC.
    pause
    exit /b 1
)
start "" http://localhost:8006
echo Box is up. Screen: http://localhost:8006
ping -n 6 127.0.0.1 >nul
