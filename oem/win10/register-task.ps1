# Registers a logon scheduled task that re-runs provision.ps1 at every logon
# (so the MCP server comes back after reboots and picks up a rotated key).
# Idempotent; falls back to schtasks.exe on stripped images.
$ErrorActionPreference = 'SilentlyContinue'
$cmd = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\NexoBox\provision.ps1'
try {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $cmd
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'Docker' -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'NexoBoxProvision' -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
} catch {
    schtasks /Create /TN NexoBoxProvision /TR "powershell $cmd" /SC ONLOGON /RL HIGHEST /F | Out-Null
}
