# ============================================================
#  NexoGate - clone worker (run in the background by the server)
#  Copies the base disk, injects a fresh MCP key, generates config and brings it up.
# ============================================================
param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$SourceDir,   # base (E:\projetos\box) or another instance
    [Parameter(Mandatory)] [string]$Root
)
$ErrorActionPreference = 'Stop'
$dir  = Join-Path $Root "instances\$Name"
$meta = Join-Path $dir 'instance.json'
$log  = Join-Path $dir 'clone.log'
function L($m){ Add-Content $log ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) -Encoding utf8 }

function Set-Status($s){
    try { $j = Get-Content $meta -Raw | ConvertFrom-Json; $j.status = $s; $j | ConvertTo-Json | Set-Content $meta -Encoding utf8 } catch {}
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $env:Path = "$env:ProgramFiles\Docker\Docker\resources\bin;" + $env:Path
    }
    $j = Get-Content $meta -Raw | ConvertFrom-Json
    L "Starting clone of '$Name' from $SourceDir"

    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'storage') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'shared')  | Out-Null

    # 1. disk + METADATA (the slow step). dockur needs the companion files
    #    (windows.ver/base/boot/vars/rom) to recognize that the disk already
    #    has Windows installed - without them it reinstalls from scratch.
    #    windows.mac is SKIPPED on purpose: the clone gets a unique MAC.
    $srcStorage = Join-Path $SourceDir 'storage'
    if (-not (Test-Path (Join-Path $srcStorage 'data.qcow2')) -and -not (Test-Path (Join-Path $srcStorage 'data.img'))) {
        throw "Base has no disk at $srcStorage"
    }
    L 'Copying disk + metadata from the base...'
    Get-ChildItem $srcStorage -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'windows.mac' } |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $dir 'storage') -Force }
    L 'Disk copied.'

    # 2. oem + NEW MCP key (the guest reads shared\mcp.key first and restarts the MCP with it)
    if (Test-Path (Join-Path $SourceDir 'oem')) {
        Copy-Item (Join-Path $SourceDir 'oem') (Join-Path $dir 'oem') -Recurse -Force
    }
    Set-Content (Join-Path $dir 'oem\mcp.key')    -Value $j.mcpKey -Encoding ascii -NoNewline -ErrorAction SilentlyContinue
    Set-Content (Join-Path $dir 'shared\mcp.key') -Value $j.mcpKey -Encoding ascii -NoNewline
    # forces setup.ps1 to restart the MCP with the new key (old marker != new)
    Remove-Item (Join-Path $dir 'oem\served.key') -Force -ErrorAction SilentlyContinue
    # carry the optional app id (if any) to the clone's live shared folder
    if (Test-Path (Join-Path $dir 'oem\app.id')) {
        Copy-Item (Join-Path $dir 'oem\app.id') (Join-Path $dir 'shared\app.id') -Force -ErrorAction SilentlyContinue
    }

    # 3. .env + compose.yml for the instance
    @(
        "BOX_VERSION=10","BOX_RAM_SIZE=$($j.ram)","BOX_CPU_CORES=$($j.cpu)",
        "BOX_CPUS=$($j.cpus)","BOX_DISK_FMT=qcow2","MCP_AUTH_KEY=$($j.mcpKey)"
    ) | Set-Content (Join-Path $dir '.env') -Encoding ascii

    $compose = @"
# NexoGate - instance '$Name' (clone). Ports bound to 127.0.0.1.
services:
  windows:
    image: dockurr/windows
    container_name: nexo-$Name
    cpus: $($j.cpus)
    environment:
      VERSION: "10"
      RAM_SIZE: "$($j.ram)"
      CPU_CORES: "$($j.cpu)"
      DISK_FMT: "qcow2"
      DISK_DISCARD: "unmap"
      USERNAME: "Docker"
      PASSWORD: "admin"
      USER_PORTS: "8000"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "127.0.0.1:$($j.web):8006"
      - "127.0.0.1:$($j.rdp):3389/tcp"
      - "127.0.0.1:$($j.rdp):3389/udp"
      - "127.0.0.1:$($j.mcp):8000"
    volumes:
      - ./storage:/storage
      - ./oem:/oem
      - ./shared:/shared
    restart: unless-stopped
    stop_grace_period: 2m
"@
    Set-Content (Join-Path $dir 'compose.yml') -Value $compose -Encoding ascii
    L 'Config generated.'

    # 4. bring it up (EAP=Continue locally: docker compose stderr must not become an exception)
    wsl -d docker-desktop -u root -e sh -c 'modprobe kvm_amd 2>/dev/null; modprobe kvm_intel 2>/dev/null; true' 2>$null
    Push-Location $dir
    & {
        $ErrorActionPreference = 'Continue'
        docker compose up -d 2>&1 | ForEach-Object { L "$_" }
    }
    $ok = ($LASTEXITCODE -eq 0)
    Pop-Location

    if ($ok) { Set-Status 'running'; L "Instance '$Name' is up (web:$($j.web) mcp:$($j.mcp))." }
    else     { Set-Status 'error';   L 'docker compose failed.' }
} catch {
    L "ERROR: $_"
    Set-Status 'error'
}
