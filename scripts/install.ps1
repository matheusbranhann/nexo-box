# ============================================================
#  Nexo Box - host installer (called by install.bat)
#  Idempotent: run it as many times as needed; resumes after reboot.
#  Compatible with Windows PowerShell 5.1.
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg){ Write-Host "    WARNING: $msg" -ForegroundColor Yellow }

# Probes a native command WITHOUT letting PowerShell see stderr:
# with EAP=Stop, "cmd *> $null" throws NativeCommandError on PS 5.1.
function Test-Native($cmdLine) {
    cmd /c "$cmdLine >nul 2>&1"
    return ($LASTEXITCODE -eq 0)
}

# Real interactive user (may differ from the admin who accepted the UAC prompt)
function Get-InteractiveUser {
    try {
        $p = Get-CimInstance Win32_Process -Filter "name='explorer.exe'" | Select-Object -First 1
        if ($p) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
            if ($o.User) { return ($o.Domain + '\' + $o.User) }
        }
    } catch { }
    return ($env:USERDOMAIN + '\' + $env:USERNAME)
}

# Profile folder of the interactive user (the .wslconfig must go in THEIR profile)
function Get-InteractiveProfile($user) {
    $name = $user.Split('\')[-1]
    try {
        $prof = Get-CimInstance Win32_UserProfile |
            Where-Object { -not $_.Special -and $_.LocalPath -and ($_.LocalPath.Split('\')[-1] -ieq $name) } |
            Select-Object -First 1
        if ($prof) { return $prof.LocalPath }
    } catch { }
    return $env:USERPROFILE
}

function Wait-Network($seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { [Net.Dns]::GetHostEntry('desktop.docker.com') | Out-Null; return $true }
        catch { Start-Sleep -Seconds 5 }
    }
    return $false
}

$interactiveUser = Get-InteractiveUser
$rebootNeeded = $false

# clears the scheduled resume task from a previous run (recreated below if needed)
try { Unregister-ScheduledTask -TaskName 'NexoBoxInstall' -Confirm:$false -ErrorAction Stop } catch { }

Write-Host '============================================'
Write-Host ' Nexo Box - AI-controllable Windows in a container'
Write-Host ' Windows 11 in a container with AI access'
Write-Host '============================================'

# ---------- 1. Pre-checks ----------
Write-Step 'Checking prerequisites'
$os = Get-CimInstance Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 22000) {
    # Windows 10: dockur/windows can't run here (no /dev/kvm on Win10 WSL2).
    # Switch to the native QEMU + WHPX engine, which does not need Docker/WSL.
    Write-Host ''
    Write-Host "    Windows 10 detected (build $($os.BuildNumber))."
    Write-Host '    dockur/windows requires Windows 11, so switching to the native'
    Write-Host '    QEMU + WHPX engine for Windows 10 (no Docker/WSL required)...'
    & (Join-Path $PSScriptRoot 'install-qemu.ps1')
    exit $LASTEXITCODE
}
$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if (-not $cs.HypervisorPresent -and -not $cpu.VirtualizationFirmwareEnabled) {
    throw "Virtualization disabled in firmware. Enable 'Intel VT-x' or 'AMD SVM' in the BIOS/UEFI and run install.bat again."
}
Write-Ok "Windows 11 + virtualization available (user: $interactiveUser)"

# ---------- 2. WSL2 (required by Docker Desktop) ----------
Write-Step 'Checking WSL2'
$vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
if ($vmp.State -ne 'Enabled') {
    Write-Host '    Enabling the VirtualMachinePlatform feature...'
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All | Out-Null
    $rebootNeeded = $true
}
if (-not (Test-Native 'wsl --status')) {
    Write-Host '    Installing WSL2 (no distro)...'
    wsl.exe --install --no-distribution
    $rebootNeeded = $true
} else {
    Test-Native 'wsl --update' | Out-Null
    Write-Ok 'WSL2 present'
}

# ---------- 3. Nested virtualization (the guest needs /dev/kvm) ----------
Write-Step 'Ensuring nested virtualization in WSL2 (.wslconfig)'
$profilePath = Get-InteractiveProfile $interactiveUser
$wslConfig = Join-Path $profilePath '.wslconfig'
$content = ''
if (Test-Path $wslConfig) { $content = [string](Get-Content $wslConfig -Raw) }
if ($content -notmatch 'nestedVirtualization') {
    if ($content -match '\[wsl2\]') {
        $content = ([regex]'\[wsl2\]').Replace($content, "[wsl2]`r`nnestedVirtualization=true", 1)
    } else {
        if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $content += "`r`n" }
        $content += "[wsl2]`r`nnestedVirtualization=true`r`n"
    }
    # WriteAllText = UTF-8 without BOM; preserves accents in existing configs
    [IO.File]::WriteAllText($wslConfig, $content)
    Write-Ok ".wslconfig updated with nestedVirtualization=true ($wslConfig)"
} elseif ($content -match 'nestedVirtualization\s*=\s*false') {
    Write-Warn "nestedVirtualization=false found in $wslConfig - change it to true, otherwise the box will not boot."
} else {
    Write-Ok 'nestedVirtualization already configured'
}

# ---------- 4. Docker Desktop ----------
Write-Step 'Checking Docker Desktop'
$dockerExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
if (-not (Test-Path $dockerExe)) {
    if (-not (Wait-Network 60)) {
        Write-Warn 'No network right now - the Docker download may fail; connect to the internet.'
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host '    Installing Docker Desktop via winget (large download, please wait)...'
        winget install --id Docker.DockerDesktop -e --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) { Write-Warn "winget returned code $LASTEXITCODE, trying a direct download..." }
    }
    if (-not (Test-Path $dockerExe)) {
        Write-Host '    Downloading the official Docker Desktop installer...'
        $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
        Invoke-WebRequest -Uri 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -OutFile $installer -UseBasicParsing
        Start-Process -FilePath $installer -ArgumentList 'install','--quiet','--accept-license','--backend=wsl-2' -Wait
    }
    if (-not (Test-Path $dockerExe)) {
        throw 'Docker Desktop was not installed. Install it manually (https://www.docker.com/products/docker-desktop/) and run install.bat again.'
    }
    $rebootNeeded = $true
    Write-Ok 'Docker Desktop installed'
} else {
    Write-Ok 'Docker Desktop present'
}

# add the INTERACTIVE user to the docker-users group (takes effect after re-login)
try {
    $name = $interactiveUser.Split('\')[-1]
    $inGroup = Get-LocalGroupMember -Group 'docker-users' -ErrorAction Stop |
        Where-Object { $_.Name -like ('*\' + $name) }
    if (-not $inGroup) {
        Add-LocalGroupMember -Group 'docker-users' -Member $interactiveUser -ErrorAction Stop
        $rebootNeeded = $true
    }
} catch { }

# ---------- 5. Reboot (if needed) ----------
if ($rebootNeeded) {
    Write-Step 'Reboot required to finish WSL2/Docker'
    $batPath = Join-Path $root 'install.bat'
    try {
        # elevated scheduled task at the interactive user's logon:
        # survives a denied UAC prompt (stays scheduled) and reopens as admin
        $action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c start "" "' + $batPath + '"')
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $interactiveUser
        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName 'NexoBoxInstall' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Write-Host '    After the reboot the installer REOPENS ON ITS OWN and continues, already as administrator.'
    } catch {
        Write-Warn "Could not schedule the automatic resume ($_). After restarting, run install.bat again."
    }
    $answer = Read-Host '    Restart NOW? (Y/N)'
    if ($answer -match '^[yY]') { shutdown /r /t 5; exit 0 }
    Write-Host '    Ok - restart manually when you can; the installation continues after the reboot.'
    exit 0
}

# ---------- 6. Docker running ----------
Write-Step 'Starting Docker'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $env:Path = "$env:ProgramFiles\Docker\Docker\resources\bin;" + $env:Path
}
if (-not (Test-Native 'docker info')) {
    Start-Process -FilePath $dockerExe
    Write-Host '    Waiting for Docker Desktop to start (up to 6 min)...'
    $deadline = (Get-Date).AddMinutes(6)
    $up = $false
    do {
        Start-Sleep -Seconds 5
        $up = Test-Native 'docker info'
    } while (-not $up -and (Get-Date) -lt $deadline)
    if (-not $up) {
        throw 'Docker did not respond. Open Docker Desktop, finish the first-run wizard, and run install.bat again.'
    }
}
Write-Ok 'Docker running'

# ---------- 7. Box configuration (.env + MCP key) ----------
Write-Step 'Configuring the box'
$envFile = Join-Path $root '.env'
if (-not (Test-Path $envFile)) {
    $key = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
    @(
        '# Nexo Box configuration (read by docker compose). Generated by the installer.',
        '# If there is a .iso in the folder, BOX_VERSION is IGNORED (the local ISO is used).',
        '# BOX_VERSION without an ISO: win10x64-ltsc = Win10 LTSC, the leanest (~4.9 GB);',
        '#   others: win10x64-iot (supported until 2032), 11l (Win11 LTSC), 11 (Win11 Pro).',
        'BOX_VERSION=win10x64-ltsc',
        '# Lean by default: 4 GB RAM, 2 cores, thin disk (qcow2) capped at 32 GB.',
        'BOX_RAM_SIZE=4G',
        'BOX_CPU_CORES=2',
        'BOX_CPUS=2.0',
        'BOX_DISK_SIZE=32G',
        'BOX_DISK_FMT=qcow2',
        'BOX_USERNAME=Docker',
        'BOX_PASSWORD=admin',
        "MCP_AUTH_KEY=$key",
        '# Optional: a numeric Steam app id to auto-install in the box.',
        '# Leave empty for a plain box with no extra software.',
        'STEAM_APP_ID='
    ) | Set-Content -Path $envFile -Encoding ascii
    Write-Ok '.env created with a new MCP key'
} else {
    Write-Ok '.env already exists (kept)'
}
$key = ((Get-Content $envFile | Where-Object { $_ -match '^MCP_AUTH_KEY=' }) -replace '^MCP_AUTH_KEY=', '')
if (-not $key) { throw 'MCP_AUTH_KEY not found in .env - delete the .env and run again.' }

New-Item -ItemType Directory -Force -Path (Join-Path $root 'storage') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'shared')  | Out-Null

# the key travels two paths: oem/ (copied ONCE during Windows installation)
# and shared/ (the live \\host.lan\Data folder - lets you rotate the key without reinstalling the guest)
Set-Content -Path (Join-Path $root 'oem\mcp.key')    -Value $key -Encoding ascii -NoNewline
Set-Content -Path (Join-Path $root 'shared\mcp.key') -Value $key -Encoding ascii -NoNewline

# optional Steam app id -> baked into oem/ (frozen at install) + shared/ (live override)
$appId = ((Get-Content $envFile | Where-Object { $_ -match '^STEAM_APP_ID=' }) -replace '^STEAM_APP_ID=', '').Trim()
if ($appId) {
    Set-Content -Path (Join-Path $root 'oem\app.id')    -Value $appId -Encoding ascii -NoNewline
    Set-Content -Path (Join-Path $root 'shared\app.id') -Value $appId -Encoding ascii -NoNewline
} else {
    Remove-Item (Join-Path $root 'oem\app.id'), (Join-Path $root 'shared\app.id') -Force -ErrorAction SilentlyContinue
}

# ---------- 8. Local ISO (use YOUR ISO instead of downloading) ----------
# If there is a .iso in the root of the folder, the box installs from it.
# Writes a compose.override.yml (merged automatically by compose).
Write-Step 'Looking for a Windows ISO in the folder'
$override = Join-Path $root 'compose.override.yml'
$iso = Get-ChildItem -Path $root -Filter *.iso -File -ErrorAction SilentlyContinue |
       Sort-Object Length -Descending | Select-Object -First 1
if ($iso) {
    # detects 10 vs 11 in the ISO to pick the right dockur answer file
    # (ensures the automatic installation + OEM hook even if NTLite altered the metadata)
    $winMajor = $null
    try {
        $mount  = Mount-DiskImage -ImagePath $iso.FullName -PassThru -ErrorAction Stop
        $letter = ($mount | Get-Volume).DriveLetter
        $src = @("${letter}:\sources\install.wim", "${letter}:\sources\install.esd") |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($src) {
            $img = Get-WindowsImage -ImagePath $src -Index 1 -ErrorAction Stop
            if     ($img.ImageName -match '11') { $winMajor = '11' }
            elseif ($img.ImageName -match '10') { $winMajor = '10' }
        }
    } catch { Write-Warn "Could not read the ISO version: $_" }
    finally { try { Dismount-DiskImage -ImagePath $iso.FullName | Out-Null } catch { } }
    if (-not $winMajor) {
        if ($iso.Name -match '11') { $winMajor = '11' } else { $winMajor = '10' }
        Write-Warn "ISO version not detected; assuming Windows $winMajor from the file name."
    }
    $answer = "assets/win${winMajor}x64.xml"
    @(
        '# Generated by the installer: uses the local ISO instead of downloading Windows.',
        '# Delete this file to go back to downloading (BOX_VERSION from .env).',
        'services:',
        '  windows:',
        '    volumes:',
        "      - ./$($iso.Name):/custom.iso",
        "      - ./${answer}:/custom.xml"
    ) | Set-Content -Path $override -Encoding ascii
    Write-Ok "Using the local ISO: $($iso.Name) (Windows $winMajor)"
} else {
    if (Test-Path $override) { Remove-Item $override -Force }
    Write-Ok 'No ISO in the folder - Windows will be downloaded (BOX_VERSION from .env).'
}

# ---------- 9. KVM module in the WSL2 kernel ----------
# Recent WSL2 kernels (6.6+) ship KVM as a module and do NOT load it
# on their own - without it the container fails with "/dev/kvm: no such file".
Write-Step 'Loading the KVM module in WSL2'
wsl -d docker-desktop -u root -e sh -c 'modprobe kvm_amd 2>/dev/null; modprobe kvm_intel 2>/dev/null; true'
cmd /c "wsl -d docker-desktop -e ls /dev/kvm >nul 2>&1"
$kvmOk = ($LASTEXITCODE -eq 0)
if ($kvmOk) { Write-Ok '/dev/kvm available' }
else { Write-Warn '/dev/kvm did not appear - the box may fail to boot (see Troubleshooting in the README).' }

# ---------- 10. Bring the box up ----------
Write-Step 'Bringing the box up (docker compose up -d)'
docker compose up -d
if ($LASTEXITCODE -ne 0) { throw 'docker compose failed - see the message above.' }
Write-Ok 'Container is up'

# ---------- 11. Summary ----------
Write-Step 'Host installation complete!'
Write-Host ''
Write-Host '  The box Windows will install ITSELF now (20 to 40 min).'
Write-Host '  Follow along in the browser:  http://localhost:8006'
Write-Host ''
Write-Host '  When the desktop appears, the box provisions itself automatically:'
Write-Host '   it installs the AI server (Windows-MCP) and whatever oem/setup.ps1 defines.'
Write-Host '   From there, connect an AI agent, use the screen, and install any software you need.'
Write-Host ''
Write-Host '  Access (only from this PC, for security):'
Write-Host '   - Screen (noVNC):  http://localhost:8006   <- use this to view the box'
Write-Host "   - AI (MCP HTTP):   http://localhost:8000/mcp  key: $key"
Write-Host ''
Write-Host '  To connect Claude Code: double-click connect-claude.bat'
Write-Host '  Details, other AIs, and notes: README.md'
Start-Process 'http://localhost:8006'
