# ============================================================
#  NexoGate - clone worker (QEMU + WHPX engine)
#  Runs detached (started by server-qemu.ps1). Creates an instant thin
#  clone of the source disk (qcow2 backing file), builds the instance's
#  config CD (its own MCP key), boots the VM, flips status running/error.
#  The source (base or another instance) MUST be stopped: a backing-file
#  clone references it read-only, so a running/changing source corrupts it.
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
$log  = Join-Path $dir 'clone.log'
function Log($m) { try { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) } catch { } }
function Set-Status([string]$s) {
    try { $j = Get-Content $meta -Raw | ConvertFrom-Json; $j.status = $s; $j | ConvertTo-Json | Set-Content $meta -Encoding utf8 } catch { }
}

try {
    Log "clone '$Name' starting; source disk = $SourceDisk"
    if (-not (Test-Path $SourceDisk)) { throw "Source disk not found: $SourceDisk" }
    $i = Get-Content $meta -Raw | ConvertFrom-Json

    # the source must be stopped (backing-file clone references it read-only)
    $srcVm = if ($i.source -and $i.source -ne 'base') { "nexo-$($i.source)" } else { 'nexo-base' }
    if (Test-VmRunning -Name $srcVm) {
        throw "Source '$($i.source)' is running. Stop it first (the base/source must be off to clone)."
    }

    # 1. instant thin clone via qcow2 backing file (writes go to the overlay; source stays frozen)
    $disk = Join-Path $dir 'disk.qcow2'
    Remove-Item $disk -Force -ErrorAction SilentlyContinue
    $img = Find-QemuImg
    if (-not $img) { throw 'qemu-img not found.' }
    & $img create -f qcow2 -b $SourceDisk -F qcow2 $disk 2>&1 | ForEach-Object { Log $_ }
    if (-not (Test-Path $disk)) { throw 'qemu-img could not create the backing clone.' }
    Log ("clone disk created ({0} KB overlay)" -f [math]::Round((Get-Item $disk).Length/1KB,1))

    # 2. per-instance config CD (its own key; app id inherited from .env)
    $appId = ''
    $envFile = Join-Path $Root '.env'
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match '^STEAM_APP_ID=' } | Select-Object -First 1
        if ($line) { $appId = ($line -replace '^STEAM_APP_ID=', '').Trim() }
    }
    $cfg = Join-Path $dir 'config.iso'
    Build-NexoConfigIso -OutIso $cfg -Key $i.mcpKey -AppId $appId | Out-Null
    Log 'config CD built'

    # 3. boot it
    $vmArgs = Get-VmArgs -Name "nexo-$Name" -DiskPath $disk -Ram $i.ram -Cores ([int]$i.cpu) -Slot ([int]$i.slot) -ConfigIso $cfg
    Start-Vm -VmArgs $vmArgs -PidFile (Join-Path $dir 'vm.pid') | Out-Null
    Log 'VM launched'
    Set-Status 'running'
    Log 'status -> running'
} catch {
    Log ("ERROR: $_")
    Set-Status 'error'
}
