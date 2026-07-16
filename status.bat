@echo off
rem TBH Box - shows the box state and the access details
setlocal
cd /d "%~dp0"
setlocal enabledelayedexpansion

echo ===== Container =====
docker compose ps
echo.

set "KEY="
if exist ".env" (
    for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
        if /i "%%a"=="MCP_AUTH_KEY" set "KEY=%%b"
    )
)

echo ===== Access =====
echo  Screen (noVNC):  http://localhost:8006
echo  RDP:             localhost:3389  (note: RDP can break the MCP screen capture - prefer noVNC)
if defined KEY (
    echo  AI ^(MCP^):        http://localhost:8000/mcp
    echo  MCP key:         !KEY!
) else (
    echo  AI ^(MCP^):        run install.bat to generate the .env with the key
)

where curl >nul 2>&1
if %errorlevel% equ 0 (
    for /f %%c in ('curl -s -m 3 -o nul -w "%%{http_code}" http://localhost:8000/mcp 2^>nul') do set "HC=%%c"
    if "!HC!"=="000" (
        echo  MCP server:      offline - is the box still installing? See http://localhost:8006
    ) else if "!HC!"=="" (
        echo  MCP server:      offline - is the box still installing? See http://localhost:8006
    ) else (
        echo  MCP server:      ONLINE ^(HTTP !HC!^)
    )
)
echo.
pause
