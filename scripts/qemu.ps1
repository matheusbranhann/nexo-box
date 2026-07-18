# ============================================================
#  Nexo Box - QEMU engine library (Windows 10 host, WHPX)
#  Dot-sourced by install-qemu.ps1 and nexo/server-qemu.ps1.
#
#  Why this exists: dockur/windows needs /dev/kvm, which on Windows
#  only comes from WSL2 nested virtualization - and that is Windows 11
#  only (Windows 10 forces ExposeVirtualizationExtensions=false). On a
#  Windows 10 host we therefore run the guest with QEMU directly, using
#  the Windows Hypervisor Platform (WHPX) accelerator.
#
#  Hard-won configuration facts baked in below:
#   - WHPX breaks OVMF/UEFI via pflash (MMIO emulation bug, worse on AMD)
#     => we boot LEGACY BIOS (SeaBIOS), never UEFI.
#   - virtio-scsi/virtio-blk/virtio-net need drivers a fresh Windows lacks
#     => disk on SATA/AHCI (ich9-ahci + ide-hd) and NIC on e1000 (in-box).
#   - WHPX does not support "-cpu host" on x86 => "-cpu qemu64".
#   - kernel-irqchip=off avoids MSI injection failures on Ryzen.
#  Compatible with Windows PowerShell 5.1. ASCII-only output.
# ============================================================

$ErrorActionPreference = 'Stop'

function Get-BoxRoot { return (Split-Path -Parent $PSScriptRoot) }

function Get-QemuDir { return (Join-Path (Get-BoxRoot) 'qemu') }

# --- locate qemu-system-x86_64.exe (bundled first, then common installs, then PATH) ---
function Find-QemuExe {
    $candidates = @(
        (Join-Path (Get-QemuDir) 'qemu-system-x86_64.exe'),
        (Join-Path ${env:ProgramFiles} 'qemu\qemu-system-x86_64.exe'),
        'C:\qemu\qemu-system-x86_64.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command 'qemu-system-x86_64.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-QemuImg {
    $exe = Find-QemuExe
    if ($exe) {
        $img = Join-Path (Split-Path -Parent $exe) 'qemu-img.exe'
        if (Test-Path $img) { return $img }
    }
    $cmd = Get-Command 'qemu-img.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# --- download + silent-install QEMU into ./qemu (idempotent) ---
# The weilnetz.de builds bundle SeaBIOS + OVMF + VGA/NIC option ROMs, so
# no separate firmware download is needed. NSIS installer: /S silent, /D dir.
function Install-Qemu {
    $existing = Find-QemuExe
    if ($existing) { return $existing }

    $qdir = Get-QemuDir
    New-Item -ItemType Directory -Force -Path $qdir | Out-Null
    $setup = Join-Path $env:TEMP 'qemu-w64-setup.exe'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Find the newest qemu-w64-setup-YYYYMMDD.exe on the index (dates sort lexically).
    $base = 'https://qemu.weilnetz.de/w64/'
    $file = $null
    try {
        $idx = Invoke-WebRequest -Uri $base -UseBasicParsing -ErrorAction Stop
        $names = [regex]::Matches($idx.Content, 'qemu-w64-setup-\d{8}\.exe') | ForEach-Object { $_.Value } | Sort-Object -Unique
        if ($names.Count) { $file = $names[-1] }
    } catch { Write-Host '    (could not read the QEMU index; using a known build)' }
    if (-not $file) { $file = 'qemu-w64-setup-20260501.exe' }

    $got = $false
    foreach ($u in @(($base + $file), 'https://qemu.weilnetz.de/w64/qemu-w64-setup-20260501.exe')) {
        try {
            Write-Host "    Downloading QEMU: $u"
            Invoke-WebRequest -Uri $u -OutFile $setup -UseBasicParsing -ErrorAction Stop
            if ((Test-Path $setup) -and (Get-Item $setup).Length -gt 50MB) { $got = $true; break }
        } catch { Write-Host "    (that build was unavailable, trying another)" }
    }
    if (-not $got) {
        throw 'Could not download QEMU. Download qemu-w64-setup from https://qemu.weilnetz.de/w64/ manually, install it into the box "qemu" folder, and run install.bat again.'
    }

    Write-Host '    Installing QEMU (silent)...'
    Start-Process -FilePath $setup -ArgumentList '/S', "/D=$qdir" -Wait
    Remove-Item $setup -Force -ErrorAction SilentlyContinue

    $exe = Find-QemuExe
    if (-not $exe) { throw "QEMU install finished but qemu-system-x86_64.exe was not found under $qdir." }
    return $exe
}

# --- build an ISO from a folder using IMAPI2 (built into Windows; no ADK needed) ---
# Used for the autounattend/config CD we hand to the guest.
function New-IsoFile {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [string]$VolumeName = 'NEXOCFG'
    )
    if (-not ([System.Management.Automation.PSTypeName]'NexoISOFile').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class NexoISOFile {
  public static void Create(string path, object stream, int blockSize, int totalBlocks) {
    IStream i = (IStream)stream;
    FileStream o = File.OpenWrite(path);
    byte[] buf = new byte[blockSize];
    IntPtr p = Marshal.AllocHGlobal(4);
    try {
      while (totalBlocks-- > 0) {
        i.Read(buf, blockSize, p);
        int read = Marshal.ReadInt32(p);
        o.Write(buf, 0, read);
      }
    } finally {
      o.Flush(); o.Close();
      Marshal.FreeHGlobal(p);
    }
  }
}
'@
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3   # ISO9660 (1) | Joliet (2)
    $fsi.VolumeName = $VolumeName
    # includeBaseDirectory=$false => the folder's CONTENTS land at the ISO root
    $fsi.Root.AddTree($SourceDir, $false)
    $img = $fsi.CreateResultImage()
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    [NexoISOFile]::Create($OutFile, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
    return $OutFile
}

# --- assemble a config CD for a VM (autounattend + provisioning + live key) ---
# The base install CD carries the answer file + scripts (-IncludeInstaller);
# clone CDs carry only the marker + live key/app id (scripts already on C:).
function Build-NexoConfigIso {
    param(
        [Parameter(Mandatory=$true)][string]$OutIso,
        [Parameter(Mandatory=$true)][string]$Key,
        [string]$AppId = $null,
        [switch]$IncludeInstaller
    )
    $root = Get-BoxRoot
    $stage = Join-Path $env:TEMP ('nexocfg_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Set-Content -Path (Join-Path $stage 'nexo.id') -Value 'nexo-box' -Encoding ascii -NoNewline
        Set-Content -Path (Join-Path $stage 'mcp.key') -Value $Key -Encoding ascii -NoNewline
        if ($AppId) { Set-Content -Path (Join-Path $stage 'app.id') -Value $AppId -Encoding ascii -NoNewline }
        if ($IncludeInstaller) {
            Copy-Item (Join-Path $root 'assets\win10x64-bios.xml') (Join-Path $stage 'autounattend.xml') -Force
            Copy-Item (Join-Path $root 'oem\win10\bootstrap.cmd')  (Join-Path $stage 'bootstrap.cmd')    -Force
            $nb = Join-Path $stage 'nexobox'
            New-Item -ItemType Directory -Force -Path $nb | Out-Null
            Copy-Item (Join-Path $root 'oem\win10\provision.ps1')     $nb -Force
            Copy-Item (Join-Path $root 'oem\win10\register-task.ps1') $nb -Force
            if (Test-Path (Join-Path $root 'oem\optimize.ps1')) { Copy-Item (Join-Path $root 'oem\optimize.ps1') $nb -Force }
        }
        New-IsoFile -SourceDir $stage -OutFile $OutIso -VolumeName 'NEXOCFG' | Out-Null
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $OutIso
}

# --- port scheme per slot (0 = base). All bound to 127.0.0.1. ---
function Get-VmPorts {
    param([int]$Slot = 0)
    return [pscustomobject]@{
        Slot       = $Slot
        McpPort    = 8000 + $Slot     # guest 8000 (Windows-MCP) -> host 8000+slot
        RdpPort    = 3389 + $Slot     # guest 3389 (RDP)         -> host 3389+slot
        VncDisplay = $Slot            # VNC display N -> TCP 5900+N
        VncPort    = 5900 + $Slot
        MonPort    = 55900 + $Slot    # QEMU monitor (host only)
    }
}

# --- assemble the QEMU argument array for a VM ---
# Params:
#   Name       friendly VM name (also used for -name)
#   DiskPath   qcow2 disk
#   Ram        e.g. "4G"
#   Cores      e.g. 2
#   Slot       port slot (0 = base)
#   InstallIso Windows ISO to attach (install mode); $null to just boot the disk
#   ConfigIso  the autounattend/config CD to attach; $null to skip
function Get-VmArgs {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$DiskPath,
        [string]$Ram = '4G',
        [int]$Cores = 2,
        [int]$Slot = 0,
        [string]$InstallIso = $null,
        [string]$ConfigIso = $null
    )
    $p = Get-VmPorts -Slot $Slot
    # bind the forwarded ports (MCP, RDP) to 0.0.0.0 so the box is reachable from
    # other PCs on the LAN (not just the host). VNC is bound to 0.0.0.0 below too.
    $hostfwd = "hostfwd=tcp:0.0.0.0:$($p.McpPort)-:8000,hostfwd=tcp:0.0.0.0:$($p.RdpPort)-:3389"

    $vmArgs = @(
        # NOTE: use WHPX's DEFAULT in-kernel irqchip. "kernel-irqchip=off" makes a
        # Windows guest hang forever at the boot logo (stuck in HLT waiting for an
        # interrupt the split/off irqchip never delivers). Verified on Ryzen Zen4/Zen5:
        # default irqchip installs Windows fine; kernel-irqchip=off never boots it.
        '-accel','whpx',
        '-machine','pc',
        # qemu64 minus x2apic: with x2apic on, WHPX triple-faults (VP exit 4,
        # "interrupt vector 0") when the INSTALLED Windows boots. -x2apic makes
        # Windows use legacy xAPIC and boots cleanly. Verified on Ryzen Zen4/Zen5.
        '-cpu','qemu64,-x2apic',
        '-smp',"$Cores",
        '-m',"$Ram",
        # boot disk on AHCI/SATA (in-box Windows driver; no virtio needed)
        '-drive',"file=$DiskPath,if=none,id=d0,format=qcow2",
        '-device','ich9-ahci,id=ahci',
        '-device','ide-hd,drive=d0,bus=ahci.0',
        # user-mode networking + e1000 (in-box driver) + host port forwards
        '-netdev',"user,id=n0,$hostfwd",
        '-device','e1000,netdev=n0',
        '-vga','std',
        '-vnc',"0.0.0.0:$($p.VncDisplay)",
        '-rtc','base=localtime',
        '-monitor',"tcp:127.0.0.1:$($p.MonPort),server,nowait",
        '-name',$Name
    )

    $cdIndex = 1
    if ($InstallIso) {
        $vmArgs += @('-drive',"file=$InstallIso,media=cdrom,index=$cdIndex,readonly=on"); $cdIndex++
    }
    if ($ConfigIso) {
        $vmArgs += @('-drive',"file=$ConfigIso,media=cdrom,index=$cdIndex,readonly=on"); $cdIndex++
    }
    if ($InstallIso) {
        # order=dc: an EMPTY disk falls through to the CD (starts install); once
        # Windows is installed, the CD's "press any key" times out (~5s) and the
        # now-bootable disk boots. Paired with the install loop (Start-InstallLoop),
        # this carries the guest through Setup's multiple reboots to completion.
        $vmArgs += @('-boot','order=dc,menu=off')
    }
    return ,$vmArgs
}

# --- join an argument array into a command line, quoting args with spaces ---
# Start-Process -ArgumentList (array) on Windows PowerShell 5.1 does NOT quote
# elements containing spaces, which breaks "-drive file=C:\...\a b\x.qcow2,..."
# when the path has a space (e.g. a user profile like "renan santtops").
function ConvertTo-ArgString {
    param([string[]]$Items)
    ($Items | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

# --- start a VM under a relaunch loop; returns the wrapper process object ---
# QEMU EXITS whenever the guest reboots or powers off (Windows does this on first
# boot of a fresh clone, on updates, etc.). Launching qemu directly leaves it dead
# after the first reboot. A loop wrapper (cmd) relaunches it, so the box stays up and
# also survives being orphaned by a short-lived launcher. Stop-Vm kills the wrapper.
function Start-Vm {
    param([string[]]$VmArgs, [string]$PidFile = $null)
    $exe = Find-QemuExe
    if (-not $exe) { throw 'QEMU not found. Run install.bat (it installs QEMU on Windows 10).' }
    $argStr = ConvertTo-ArgString $VmArgs
    $vmName = 'vm'
    for ($k = 0; $k -lt ($VmArgs.Count - 1); $k++) { if ($VmArgs[$k] -eq '-name') { $vmName = $VmArgs[$k + 1]; break } }
    $bat = Join-Path $env:TEMP "nexo-loop-$vmName.bat"
    $err = Join-Path $env:TEMP "nexo-loop-$vmName.err"
    @('@echo off', "cd /d ""$(Split-Path $exe)""", ':loop', """$exe"" $argStr 2>>""$err""", 'timeout /t 3 /nobreak >nul', 'goto loop') | Set-Content -Path $bat -Encoding ascii
    $proc = Start-Process -FilePath $bat -WindowStyle Minimized -PassThru
    if ($PidFile) { Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii -NoNewline }
    return $proc
}

# --- send a command to the QEMU human monitor over TCP ---
function Send-VmMonitor {
    param([int]$MonPort, [string]$Command)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $MonPort)
        $s = $c.GetStream()
        Start-Sleep -Milliseconds 200
        $bytes = [Text.Encoding]::ASCII.GetBytes($Command + "`n")
        $s.Write($bytes, 0, $bytes.Length); $s.Flush()
        Start-Sleep -Milliseconds 200
        $c.Close()
        return $true
    } catch { return $false }
}

# --- get past the CD's "Press any key to boot from CD" prompt on a fresh install ---
# The Windows boot media waits ~5s for a keypress; unattended VMs have no one to
# press it. We tap Enter for the first several seconds via the monitor.
function Push-BootPrompt {
    param([int]$MonPort, [int]$Seconds = 18)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Send-VmMonitor -MonPort $MonPort -Command 'sendkey ret' | Out-Null
        Start-Sleep -Seconds 1
    }
}

# --- stop a VM: kill its relaunch loop first, then power down / kill QEMU ---
# $VmName is the QEMU -name value (e.g. "nexo-player01"). MonPort optional for ACPI powerdown.
function Stop-Vm {
    param([string]$VmName, [int]$MonPort = 0, [int]$WaitSec = 60)
    # 1. kill the relaunch loop so it does not bring QEMU back
    if ($VmName) {
        $leaf = "nexo-loop-$VmName.bat"
        Get-CimInstance Win32_Process -Filter "name='cmd.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match [regex]::Escape($leaf) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    # 2. graceful ACPI powerdown
    if ($MonPort -gt 0) { Send-VmMonitor -MonPort $MonPort -Command 'system_powerdown' | Out-Null }
    # 3. wait for the guest to power off, else force-kill the QEMU process
    if ($VmName) {
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-VmProcess -Name $VmName)) { return $true }
            Start-Sleep -Seconds 3
        }
        $pr = Get-VmProcess -Name $VmName
        if ($pr) { Stop-Process -Id ([int]$pr.ProcessId) -Force -ErrorAction SilentlyContinue }
    }
    return $true
}

# --- is a QEMU process for this VM name alive? ---
function Test-VmRunning {
    param([string]$Name)
    $exe = Find-QemuExe
    if (-not $exe) { return $false }
    $procs = Get-CimInstance Win32_Process -Filter "name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue
    foreach ($pr in $procs) {
        if ($pr.CommandLine -and ($pr.CommandLine -match [regex]::Escape("-name $Name") -or $pr.CommandLine -match ("-name\s+" + [regex]::Escape($Name) + "\b"))) {
            return $true
        }
    }
    return $false
}

function Get-VmProcess {
    param([string]$Name)
    $procs = Get-CimInstance Win32_Process -Filter "name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue
    foreach ($pr in $procs) {
        if ($pr.CommandLine -and $pr.CommandLine -match ("-name\s+" + [regex]::Escape($Name))) { return $pr }
    }
    return $null
}

# --- wait until a TCP port accepts a connection (used to detect "guest ready") ---
function Wait-Tcp {
    param([int]$Port, [int]$TimeoutSec = 2400)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) { $c.Close(); return $true }
            $c.Close()
        } catch { }
        Start-Sleep -Seconds 5
    }
    return $false
}

# --- wait until the guest's Windows-MCP server actually answers HTTP ---
# (a raw TCP check is a FALSE POSITIVE with user-mode hostfwd: QEMU accepts the
#  connection even when nothing listens in the guest. A real HTTP request returns
#  a status - 401, since MCP needs the Bearer key - only once the guest MCP is up.)
function Wait-Mcp {
    param([int]$Port, [int]$TimeoutSec = 3000)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest "http://127.0.0.1:$Port/mcp" -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop | Out-Null
            return $true
        } catch {
            if ($_.Exception.Response) { return $true }   # got an HTTP status = MCP is up
        }
        Start-Sleep -Seconds 10
    }
    return $false
}

# --- run a VM under a relaunch loop (survives Windows Setup's reboots) ---
# QEMU exits when the guest reboots/powers off at the WinPE->installed transition;
# the loop relaunches it (booting the disk) so the unattended install completes.
function Start-InstallLoop {
    param([Parameter(Mandatory=$true)][string[]]$VmArgs,
          [Parameter(Mandatory=$true)][string]$LoopBat,
          [Parameter(Mandatory=$true)][string]$ErrLog)
    $exe = Find-QemuExe
    if (-not $exe) { throw 'QEMU not found. Run install.bat (it installs QEMU on Windows 10).' }
    $argStr = ConvertTo-ArgString $VmArgs
    Remove-Item $ErrLog -Force -ErrorAction SilentlyContinue
    @(
        '@echo off',
        "cd /d ""$(Split-Path $exe)""",
        ':loop',
        """$exe"" $argStr 2>>""$ErrLog""",
        'timeout /t 3 /nobreak >nul',
        'goto loop'
    ) | Set-Content -Path $LoopBat -Encoding ascii
    Start-Process -FilePath $LoopBat -WindowStyle Minimized | Out-Null
}

# --- stop the install loop wrapper (so it stops relaunching QEMU) ---
function Stop-InstallLoop {
    param([Parameter(Mandatory=$true)][string]$LoopBat)
    $leaf = Split-Path $LoopBat -Leaf
    Get-CimInstance Win32_Process -Filter "name='cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($leaf) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}
