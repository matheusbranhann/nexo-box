@echo off
rem ============================================================
rem  NexoGate - instance manager (opens the dashboard)
rem ============================================================
setlocal
cd /d "%~dp0"

rem HttpListener needs elevation to bind - auto-elevate
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    set "SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    exit /b
)

rem open the browser on the chosen port as soon as the server writes the URL
del "%~dp0nexo\active.url" >nul 2>&1
start "" powershell -NoProfile -WindowStyle Hidden -Command "$u='%~dp0nexo\active.url'; for($i=0;$i -lt 40;$i++){ if(Test-Path $u){ Start-Process (Get-Content $u -Raw).Trim(); break }; Start-Sleep -Milliseconds 400 }"

echo.
echo   Starting NexoGate... the browser opens on its own.
echo   Close this window to stop the server.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0nexo\server.ps1"
