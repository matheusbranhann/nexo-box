# ============================================================
#  Nexo Box - guest provisioning for the QEMU + WHPX engine
#  (Windows 10 host). Runs at first logon (via bootstrap.cmd) and at
#  every logon after that (via the NexoBoxProvision scheduled task).
#  Idempotent. Compatible with Windows PowerShell 5.1. ASCII-only.
#
#  Unlike the Docker engine there is no \\host.lan\Data share, so the
#  live MCP key + optional app id are read from the config CD (label
#  NEXOCFG, marker file nexo.id), with a baked C:\NexoBox fallback.
# ============================================================
$ErrorActionPreference = 'Continue'
try { Start-Transcript -Path 'C:\NexoBox\provision.log' -Append | Out-Null } catch { }

# ---------- locate the config CD (holds the live mcp.key / app.id) ----------
function Find-ConfigDrive {
    foreach ($n in 68..90) {                    # drive letters D..Z
        $root = ([char]$n) + ':\'
        try { if (Test-Path (Join-Path $root 'nexo.id')) { return $root } } catch { }
    }
    return $null
}
$cfg = Find-ConfigDrive

function Read-Config([string]$fileName) {
    if ($cfg) {
        $p = Join-Path $cfg $fileName
        try { if (Test-Path $p) { $v = ([string](Get-Content $p -Raw)).Trim(); if ($v) { return $v } } } catch { }
    }
    $baked = Join-Path 'C:\NexoBox' $fileName
    try { if (Test-Path $baked) { $v = ([string](Get-Content $baked -Raw)).Trim(); if ($v) { return $v } } } catch { }
    return $null
}

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
        catch { Write-Output "Attempt $i failed ($Name): $_"; Start-Sleep -Seconds 20 }
    }
    Write-Output "$Name failed after 3 attempts (will retry at the next logon)"
    return $false
}

# ---------- wait for the network to come up (user-mode NAT + DHCP) ----------
$deadline = (Get-Date).AddMinutes(2)
while ((Get-Date) -lt $deadline) {
    try { [Net.Dns]::GetHostEntry('astral.sh') | Out-Null; break }
    catch { Start-Sleep -Seconds 10 }
}

# ---------- clock: RTC is local time on this engine (-rtc base=localtime) ----------
# We still resync so apps that validate the date do not reject a drifted clock.
try {
    Set-Service w32time -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service w32time -ErrorAction SilentlyContinue
    w32tm /resync /force 2>$null | Out-Null
} catch { }

# ---------- power: never sleep ----------
powercfg /change standby-timeout-ac 0 2>$null
powercfg /change monitor-timeout-ac 0 2>$null
powercfg /change hibernate-timeout-ac 0 2>$null
powercfg /hibernate off 2>$null

# ---------- make sure RDP is on (reinforces the answer file) ----------
try {
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f | Out-Null
    netsh advfirewall firewall set rule group="remote desktop" new enable=Yes 2>$null | Out-Null
} catch { }

# ---------- aggressive optimization (runs ONCE, in the background) ----------
$optFlag = 'C:\NexoBox\optimized.done'
if ((Test-Path 'C:\NexoBox\optimize.ps1') -and -not (Test-Path $optFlag)) {
    Write-Output 'Triggering Windows optimization (once, in the background)...'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\NexoBox\optimize.ps1'
    Set-Content -Path $optFlag -Value (Get-Date) -Encoding ascii
}

# ---------- optional Steam app (only if an app id was configured) ----------
$appId = Read-Config 'app.id'
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

# ---------- Windows-MCP (needs Python 3.13+; uv fetches it) ----------
$mcpExe = Join-Path $uvDir 'windows-mcp.exe'
if ((Test-Path $uv) -and -not (Test-Path $mcpExe)) {
    Write-Output 'Installing Windows-MCP...'
    Invoke-Retry {
        & $uv tool install windows-mcp --python 3.13
        if (-not (Test-Path $mcpExe)) { throw 'windows-mcp.exe did not appear after the install' }
    } 'Windows-MCP installation' | Out-Null
}

# ---------- firewall for MCP ----------
try {
    $rule = Get-NetFirewallRule -DisplayName 'Windows-MCP 8000' -ErrorAction SilentlyContinue
    if (-not $rule) {
        netsh advfirewall firewall add rule name="Windows-MCP 8000" dir=in action=allow protocol=TCP localport=8000 | Out-Null
    }
} catch { }

# ---------- MCP key (live copy from the config CD; baked fallback) ----------
$key = Read-Config 'mcp.key'

# ---------- start (or restart, if the key changed) the MCP server ----------
$servedFile = 'C:\NexoBox\served.key'
$pidFile    = 'C:\NexoBox\mcp.pid'
if ((Test-Path $mcpExe) -and $key) {
    $listening = Test-PortListening 8000
    $served = ''
    if (Test-Path $servedFile) { $served = ([string](Get-Content $servedFile -Raw)).Trim() }
    if ($listening -and $served -and ($served -ne $key)) {
        Write-Output 'MCP key changed - restarting the server...'
        $killed = $false
        try {
            if (Test-Path $pidFile) { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop; $killed = $true }
        } catch { }
        if (-not $killed) { Get-Process -Name 'windows-mcp' -ErrorAction SilentlyContinue | Stop-Process -Force }
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
    Write-Output 'WARNING: no MCP key found (config CD or C:\NexoBox\mcp.key) - server not started.'
}

# ---------- app shortcuts (only if configured and Steam is present) ----------
if ($appId -and (Test-Path $steamExe)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($pair in @(@('Install.url', "steam://install/$appId"), @('Launch.url', "steam://rungameid/$appId"))) {
        $sc = Join-Path $desktop $pair[0]
        if (-not (Test-Path $sc)) { Set-Content -Path $sc -Value "[InternetShortcut]`r`nURL=$($pair[1])" -Encoding ascii }
    }
}

try { Stop-Transcript | Out-Null } catch { }
