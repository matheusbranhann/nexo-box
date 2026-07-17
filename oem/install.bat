@echo off
rem ============================================================
rem  Nexo Box - Guest provisioning
rem  dockur/windows runs this file automatically during the
rem  final step of the Windows install (from C:\OEM).
rem ============================================================

rem open the Windows-MCP port in the guest firewall
netsh advfirewall firewall add rule name="Windows-MCP 8000" dir=in action=allow protocol=TCP localport=8000

rem run setup at every logon (idempotent: installs what is missing and starts the MCP server)
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v NexoBoxAgent /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\OEM\setup.ps1" /f

rem first run, right now
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\setup.ps1
exit /b 0
