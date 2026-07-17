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

rem stop any previous NexoGate server so this one starts clean on port 7099
rem (avoids stale HTTP.sys registrations / "connection refused" from a dead server)
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*nexo\server*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

rem open the browser on the chosen port as soon as the server writes the URL
del "%~dp0nexo\active.url" >nul 2>&1
start "" powershell -NoProfile -WindowStyle Hidden -Command "$u='%~dp0nexo\active.url'; for($i=0;$i -lt 40;$i++){ if(Test-Path $u){ Start-Process (Get-Content $u -Raw).Trim(); break }; Start-Sleep -Milliseconds 400 }"

echo.
echo   Starting NexoGate... the browser opens on its own.
echo   Close this window to stop the server.
echo.
rem pick the backend for this host: Windows 10 -> QEMU engine, Windows 11 -> Docker engine
powershell -NoProfile -ExecutionPolicy Bypass -Command "$b=[int](Get-CimInstance Win32_OperatingSystem).BuildNumber; $s=if($b -lt 22000){'server-qemu.ps1'}else{'server.ps1'}; & \"%~dp0nexo\$s\""
