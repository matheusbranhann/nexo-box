# ============================================================
#  Nexo Box - Slim down an ALREADY-INSTALLED box (no reinstall)
#  - raw 64 GB disk -> thin qcow2 (~15 GB): dockur converts on boot
#  - RAM 4G, 2 cores, hard 2-CPU host cap
#  Preserves Windows + the Steam login + the installed game.
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step($m){ Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "    OK: $m" -ForegroundColor Green }

$envFile = Join-Path $root '.env'
if (-not (Test-Path $envFile)) { throw '.env not found - run install.bat first.' }

# actual on-disk size (sparse file) via GetCompressedFileSizeW
$sig = '[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);'
$Native = Add-Type -MemberDefinition $sig -Name Nz -Namespace W32z -PassThru
function OnDiskGB($p){ $h=0; $l=$Native::GetCompressedFileSizeW($p,[ref]$h); return (([uint64]$h*4294967296 + $l)/1GB) }
function StorageGB(){ $s=0; Get-ChildItem (Join-Path $root 'storage') -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $h=0; $l=$Native::GetCompressedFileSizeW($_.FullName,[ref]$h); $s += [uint64]$h*4294967296 + $l }; return ($s/1GB) }

Write-Host '============================================'
Write-Host ' Nexo Box - Slim down an existing box'
Write-Host '============================================'
Write-Host ''
Write-Host ' This will SHUT the box DOWN for a few minutes and convert the disk.'
Write-Host ' Your Windows, the Steam login, and the game are preserved.'
$ans = Read-Host ' Continue? (Y/N)'
if ($ans -notmatch '^[yY]') { Write-Host 'Cancelled.'; exit 0 }

Write-Step 'Adjusting .env to the slim values'
# read key=value pairs (ignoring comments/blank lines), preserving what already exists
$map = [ordered]@{}
foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k,$v = $line -split '=', 2
    $map[$k.Trim()] = $v
}
# apply the slim values (keeping the existing MCP_AUTH_KEY, user, version, disk)
$map['BOX_RAM_SIZE']  = '4G'
$map['BOX_CPU_CORES'] = '2'
$map['BOX_CPUS']      = '2.0'
$map['BOX_DISK_FMT']  = 'qcow2'
if (-not $map.Contains('MCP_AUTH_KEY')) { throw 'MCP_AUTH_KEY is missing from .env - refusing to overwrite.' }

$out = @('# Nexo Box - .env (adjusted by slim.bat)')
foreach ($k in $map.Keys) { $out += "$k=$($map[$k])" }
$out | Set-Content -Path $envFile -Encoding ascii
Write-Ok 'RAM=4G, CPU_CORES=2, cpus=2.0, DISK_FMT=qcow2'

Write-Step 'Measuring the disk before'
$before = StorageGB
"    storage before: {0:N1} GB" -f $before

Write-Step 'Recreating the box (dockur converts raw -> qcow2 on boot)'
wsl -d docker-desktop -u root -e sh -c 'modprobe kvm_amd 2>/dev/null; modprobe kvm_intel 2>/dev/null; true'
docker compose down
docker compose up -d
if ($LASTEXITCODE -ne 0) { throw 'docker compose failed.' }
Write-Ok 'Box recreated - disk conversion in progress'

Write-Host ''
Write-Host '  The disk conversion runs on boot and can take a few minutes'
Write-Host '  (it reads the 64 GB once). Watch: http://localhost:8006'
Write-Host '  When Windows comes up, data.img becomes data.qcow2 (thin).'
Write-Host ''
Write-Host '  Tip to shrink it as much as possible: inside the box, once, run in an'
Write-Host '  admin prompt:  defrag C: /O   (or sdelete -z C:) and restart the box.'
Write-Host ''
Write-Host '  Run status.bat afterwards to see the new disk size. One MANUAL step'
Write-Host '  remains in the box: in the game Settings, enable the FPS cap at 20-30'
Write-Host '  (cuts most of the CPU usage). Details in the README.'
Start-Process 'http://localhost:8006'
