@echo off
rem ============================================================
rem  TBH Box - one-click installer (host)
rem  Copy the whole folder to the target PC and double-click here.
rem  Safe to run multiple times: it resumes where it left off.
rem ============================================================
setlocal
cd /d "%~dp0"

rem -- requires administrator (auto-elevates; fltmc works even when the Server service is disabled) --
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    set "TBH_SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:TBH_SELF -Verb RunAs"
    if errorlevel 1 (
        echo.
        echo Permission denied or elevation failed.
        echo Right-click install.bat and choose "Run as administrator".
        pause
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"
echo.
pause
