# ============================================================
#  NexoGate - clone worker (QEMU + WHPX engine)
#  Runs detached (started by server-qemu.ps1). Copies the source
#  disk, builds the instance's config CD (with its own MCP key),
#  boots the VM, and flips instance.json status running/error.
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$SourceDisk,
    [Parameter(Mandatory=$true)][string]$Root
)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\qemu.ps1')

$dir  = Join-Path $Root "instances\$Name"
$meta = Join-Path $dir 'instance.json'

function Set-Status([string]$s) {
    try {
        $j = Get-Content $meta -Raw | ConvertFrom-Json
        $j.status = $s
        $j | ConvertTo-Json | Set-Content $meta -Encoding utf8
    } catch { }
}

try {
    if (-not (Test-Path $SourceDisk)) { throw "Source disk not found: $SourceDisk" }
    $i = Get-Content $meta -Raw | ConvertFrom-Json

    # 1. independent copy of the source qcow2 (safe: no backing-file coupling)
    $disk = Join-Path $dir 'disk.qcow2'
    Copy-Item -LiteralPath $SourceDisk -Destination $disk -Force

    # 2. per-instance config CD (its own key; app id inherited from .env)
    $appId = ''
    $envFile = Join-Path $Root '.env'
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match '^STEAM_APP_ID=' } | Select-Object -First 1
        if ($line) { $appId = ($line -replace '^STEAM_APP_ID=', '').Trim() }
    }
    $cfg = Join-Path $dir 'config.iso'
    Build-NexoConfigIso -OutIso $cfg -Key $i.mcpKey -AppId $appId | Out-Null

    # 3. boot it
    $vmArgs = Get-VmArgs -Name "nexo-$Name" -DiskPath $disk -Ram $i.ram -Cores ([int]$i.cpu) -Slot ([int]$i.slot) -ConfigIso $cfg
    Start-Vm -VmArgs $vmArgs -PidFile (Join-Path $dir 'vm.pid') | Out-Null

    Set-Status 'running'
} catch {
    "clone-qemu error: $_" | Out-File (Join-Path $dir 'clone.log') -Encoding utf8
    Set-Status 'error'
}
