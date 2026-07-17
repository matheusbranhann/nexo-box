# ============================================================
#  Nexo Box - start the base box on the QEMU + WHPX engine (Windows 10)
#  Called by start.bat on Windows 10. Boots storage\base.qcow2 if it is
#  not already running. Safe to run at every logon (shell:startup):
#  it does nothing if the base is already up.
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'qemu.ps1')
$ErrorActionPreference = 'Continue'

$storage = Join-Path $root 'storage'
$disk = Join-Path $storage 'base.qcow2'
$cfg  = Join-Path $storage 'base-config.iso'
if (-not (Test-Path $disk)) {
    Write-Host 'Base box not built yet - run install.bat first.' -ForegroundColor Yellow
    exit 1
}

function Get-EnvValue([string]$n, [string]$d = '') {
    $envF = Join-Path $root '.env'
    if (-not (Test-Path $envF)) { return $d }
    $l = Get-Content $envF | Where-Object { $_ -match "^$n=" } | Select-Object -First 1
    if ($l) { return ($l -replace "^$n=", '').Trim() }
    return $d
}
$ram   = Get-EnvValue 'BOX_RAM_SIZE' '4G'
$cores = [int](Get-EnvValue 'BOX_CPU_CORES' '2')
$ports = Get-VmPorts -Slot 0

if (Test-VmRunning -Name 'nexo-base') {
    Write-Host 'Base box already running.' -ForegroundColor Green
} else {
    if (-not (Test-Path $cfg)) {
        Build-NexoConfigIso -OutIso $cfg -Key (Get-EnvValue 'MCP_AUTH_KEY') -AppId (Get-EnvValue 'STEAM_APP_ID') | Out-Null
    }
    $vmArgs = Get-VmArgs -Name 'nexo-base' -DiskPath $disk -Ram $ram -Cores $cores -Slot 0 -ConfigIso $cfg
    Start-Vm -VmArgs $vmArgs -PidFile (Join-Path $storage 'base.pid') | Out-Null
    Write-Host 'Base box starting...' -ForegroundColor Green
}
Write-Host ''
Write-Host ("  Screen (VNC): 127.0.0.1:{0}   (use any VNC viewer)" -f $ports.VncPort)
Write-Host ("  RDP:          127.0.0.1:{0}   (Docker / admin)" -f $ports.RdpPort)
Write-Host ("  AI (MCP):     http://127.0.0.1:{0}/mcp" -f $ports.McpPort)
