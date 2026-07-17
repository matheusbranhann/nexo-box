@echo off
rem ============================================================
rem  Nexo Box - first-logon bootstrap (runs from the config CD).
rem  Copies the provisioning scripts to C:\NexoBox, registers the
rem  per-logon provisioning task, then provisions once immediately.
rem ============================================================
set "SRC=%~dp0"
if not exist "C:\NexoBox" mkdir "C:\NexoBox"
xcopy "%SRC%nexobox\*" "C:\NexoBox\" /E /I /Y >nul 2>&1
rem carry the live key/app id forward as a baked fallback
if exist "%SRC%mcp.key" copy /Y "%SRC%mcp.key" "C:\NexoBox\mcp.key" >nul 2>&1
if exist "%SRC%app.id"  copy /Y "%SRC%app.id"  "C:\NexoBox\app.id"  >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\NexoBox\register-task.ps1" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\NexoBox\provision.ps1"
