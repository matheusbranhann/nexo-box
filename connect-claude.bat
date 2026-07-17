@echo off
rem Nexo Box - registers the box as an MCP server in Claude Code on this PC
setlocal
cd /d "%~dp0"

if not exist ".env" (
    echo .env not found - run install.bat first.
    pause
    exit /b 1
)

set "KEY="
for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    if /i "%%a"=="MCP_AUTH_KEY" set "KEY=%%b"
)
if not defined KEY (
    echo MCP_AUTH_KEY not found in .env - delete the .env and run install.bat again.
    pause
    exit /b 1
)

where claude >nul 2>&1
if %errorlevel% neq 0 (
    echo Claude Code not found on this PC. Install it and run this .bat again.
    echo For other AIs, see the "Connecting AIs" section of README.md
    pause
    exit /b 1
)

rem "call" is mandatory: if claude is a .cmd (installed via npm), control never returns without it
call claude mcp add --transport http nexo-box http://localhost:8000/mcp --header "Authorization: Bearer %KEY%"
if %errorlevel% equ 0 (
    echo.
    echo Done! In Claude Code, the box shows up as the MCP server "nexo-box".
    echo Test it: ask "take a screenshot of nexo-box".
)
pause
