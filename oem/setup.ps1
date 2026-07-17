# ============================================================
#  Nexo Box - Guest setup (runs at every logon; idempotent)
#  - Optionally installs a Steam app (only if STEAM_APP_ID is configured)
#  - Installs uv + Windows-MCP (access server for AI agents)
#  - Starts the MCP server on port 8000 (key: \\host.lan\Data\mcp.key
#    with fallback to C:\OEM\mcp.key; a key change restarts the server)
#  - Adjusts power settings (and creates app shortcuts if configured)
# ============================================================
$ErrorActionPreference = 'Continue'
try { Start-Transcript -Path 'C:\OEM\setup.log' -Append | Out-Null } catch { }

# ---------- wait for the network to come up (first boot can race with DHCP/DNS) ----------
$deadline = (Get-Date).AddMinutes(2)
while ((Get-Date) -lt $deadline) {
    try { [Net.Dns]::GetHostEntry('store.steampowered.com') | Out-Null; break }
    catch { Start-Sleep -Seconds 10 }
}

# check whether anything is listening on the port; Get-NetTCPConnection may not exist
# on stripped-down ISOs (NTLite) - falls back to netstat, a legacy built-in
function Test-PortListening([int]$Port) {
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
        return [bool]$c
    } catch {
        $out = netstat -ano -p TCP 2>$null | Select-String -Pattern (":$Port\s.*LISTENING")
        return [bool]$out
    }
}

function Invoke-Retry([scriptblock]$Block, [string]$Name) {
    for ($i = 1; $i -le 3; $i++) {
        try { & $Block; return $true }
        catch {
            Write-Output "Attempt $i failed ($Name): $_"
            Start-Sleep -Seconds 20
        }
    }
    Write-Output "$Name failed after 3 attempts (will retry at the next logon)"
    return $false
}

# ---------- clock: RTC as UTC (Linux/QEMU VM) + resync ----------
# dockur passes the hardware clock in UTC; without this, Windows runs
# ahead by the timezone offset, and games that validate the date (client_date)
# reject the connection with "bad client_date" (error 401). Fixes it durably.
try {
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f | Out-Null
    Set-Service w32time -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service w32time -ErrorAction SilentlyContinue
    w32tm /resync /force 2>$null | Out-Null
} catch { }

# ---------- power: the box never sleeps ----------
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /hibernate off 2>$null   # remove hiberfil.sys (saves disk/RAM)

# ---------- aggressive Windows optimization (runs ONCE, in the background) ----------
# optimize.ps1 disables ~28 services + background tasks, tweaks the registry,
# puts Defender in passive mode and cleans up the disk. Safe: it does not touch
# installed apps, networking, the DWM or the MCP itself (it has an exclusion list).
# Guarded by a marker so the heavy cleanup does not repeat at every logon.
$optFlag = 'C:\OEM\optimized.done'
if ((Test-Path 'C:\OEM\optimize.ps1') -and -not (Test-Path $optFlag)) {
    Write-Output 'Triggering Windows optimization (once, in the background)...'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\OEM\optimize.ps1'
    Set-Content -Path $optFlag -Value (Get-Date) -Encoding ascii
}

# ---------- optional Steam app (only if a STEAM_APP_ID was configured) ----------
# The app id travels via .env -> shared/app.id (live) or C:\OEM\app.id (baked at
# install). Leave it unset for a plain box with no extra software installed.
$appId = $null
foreach ($p in '\\host.lan\Data\app.id', 'C:\OEM\app.id') {
    try { if (Test-Path $p) { $v = ([string](Get-Content $p -Raw)).Trim(); if ($v) { $appId = $v; break } } } catch { }
}
$steamExe = "${env:ProgramFiles(x86)}\Steam\steam.exe"
if ($appId -and -not (Test-Path $steamExe)) {
    Write-Output 'Installing Steam...'
    Invoke-Retry {
        $tmp = Join-Path $env:TEMP 'SteamSetup.exe'
        Invoke-WebRequest -Uri 'https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe' -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        Unblock-File -Path $tmp -ErrorAction SilentlyContinue
        Start-Process -FilePath $tmp -ArgumentList '/S' -Wait
        if (-not (Test-Path $steamExe)) { throw 'steam.exe did not appear after the installer ran' }
    } 'Steam installation' | Out-Null
}

# ---------- uv (downloads Python on its own) ----------
$uvDir = Join-Path $env:USERPROFILE '.local\bin'
$uv    = Join-Path $uvDir 'uv.exe'
if (-not (Test-Path $uv)) {
    Write-Output 'Installing uv...'
    Invoke-Retry {
        $script = Invoke-RestMethod 'https://astral.sh/uv/install.ps1' -ErrorAction Stop
        Invoke-Expression $script
        if (-not (Test-Path $uv)) { throw 'uv.exe did not appear after the install' }
    } 'uv installation' | Out-Null
}
$env:Path = "$uvDir;$env:Path"

# ---------- Windows-MCP (requires Python 3.13+; uv downloads it if missing) ----------
$mcpExe = Join-Path $uvDir 'windows-mcp.exe'
if ((Test-Path $uv) -and -not (Test-Path $mcpExe)) {
    Write-Output 'Installing Windows-MCP...'
    Invoke-Retry {
        & $uv tool install windows-mcp --python 3.13
        if (-not (Test-Path $mcpExe)) { throw 'windows-mcp.exe did not appear after the install' }
    } 'Windows-MCP installation' | Out-Null
}

# firewall (reinforcement; the primary rule comes from C:\OEM\install.bat)
try {
    $rule = Get-NetFirewallRule -DisplayName 'Windows-MCP 8000' -ErrorAction SilentlyContinue
    if (-not $rule) {
        netsh advfirewall firewall add rule name="Windows-MCP 8000" dir=in action=allow protocol=TCP localport=8000
    }
} catch { }

# ---------- MCP key ----------
# Prefer the LIVE copy in the shared folder (\\host.lan\Data = ./shared on the host):
# it lets you change the key from the host without reinstalling the box's Windows.
# C:\OEM\mcp.key is the frozen copy from install time (fallback).
$key = $null
try {
    if (Test-Path '\\host.lan\Data\mcp.key') {
        $key = ([string](Get-Content '\\host.lan\Data\mcp.key' -Raw)).Trim()
    }
} catch { }
if (-not $key -and (Test-Path 'C:\OEM\mcp.key')) {
    $key = ([string](Get-Content 'C:\OEM\mcp.key' -Raw)).Trim()
}

# ---------- start (or restart, if the key changed) the MCP server ----------
$servedFile = 'C:\OEM\served.key'
$pidFile    = 'C:\OEM\mcp.pid'
if ((Test-Path $mcpExe) -and $key) {
    $listening = Test-PortListening 8000
    $served = ''
    if (Test-Path $servedFile) { $served = ([string](Get-Content $servedFile -Raw)).Trim() }
    if ($listening -and $served -and ($served -ne $key)) {
        Write-Output 'MCP key changed on the host - restarting the server...'
        $killed = $false
        try {
            if (Test-Path $pidFile) {
                Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop
                $killed = $true
            }
        } catch { }
        if (-not $killed) {
            Get-Process -Name 'windows-mcp' -ErrorAction SilentlyContinue | Stop-Process -Force
        }
        Start-Sleep -Seconds 2
        $listening = Test-PortListening 8000
    }
    if (-not $listening) {
        Write-Output 'Starting the Windows-MCP server on port 8000...'
        $proc = Start-Process -FilePath $mcpExe -WindowStyle Hidden -PassThru -ArgumentList @(
            'serve', '--transport', 'streamable-http',
            '--host', '0.0.0.0', '--port', '8000',
            '--auth-key', $key
        )
        Set-Content -Path $pidFile    -Value $proc.Id -Encoding ascii
        Set-Content -Path $servedFile -Value $key     -Encoding ascii -NoNewline
    }
} elseif (-not $key) {
    Write-Output 'WARNING: no MCP key found (shared/mcp.key or C:\OEM\mcp.key) - server not started.'
}

# ---------- app shortcuts (only if configured and Steam is present) ----------
if ($appId -and (Test-Path $steamExe)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $installShortcut = Join-Path $desktop 'Install.url'
    if (-not (Test-Path $installShortcut)) {
        Set-Content -Path $installShortcut -Value "[InternetShortcut]`r`nURL=steam://install/$appId" -Encoding ascii
    }
    $launchShortcut = Join-Path $desktop 'Launch.url'
    if (-not (Test-Path $launchShortcut)) {
        Set-Content -Path $launchShortcut -Value "[InternetShortcut]`r`nURL=steam://rungameid/$appId" -Encoding ascii
    }
}

try { Stop-Transcript | Out-Null } catch { }
