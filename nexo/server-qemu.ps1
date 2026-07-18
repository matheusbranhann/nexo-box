# ============================================================
#  NexoGate - instance manager backend for the QEMU + WHPX engine
#  (Windows 10 host). Same HTTP API as server.ps1 (Docker engine),
#  so the same web UI works unchanged. Binds only to 127.0.0.1.
#
#  Base template: storage\base.qcow2 (built by install.bat).
#  Instances:     instances\<name>\{disk.qcow2, config.iso, instance.json}
#  Ports/slot:    MCP 8000+N, RDP 3389+N, VNC 5900+N (all 127.0.0.1).
# ============================================================
param(
    [int]$Port = 7099,
    [string]$BindHost = '0.0.0.0'   # LAN-accessible dashboard (reach it from any PC on the network)
)
$ErrorActionPreference = 'Continue'
$Nexo        = $PSScriptRoot
$Root        = Split-Path -Parent $Nexo
$Www         = Join-Path $Nexo 'www'
$InstDir     = Join-Path $Root 'instances'
$BaseDisk    = Join-Path $Root 'storage\base.qcow2'
$CloneWorker = Join-Path $Nexo 'clone-qemu.ps1'
. (Join-Path $Root 'scripts\qemu.ps1')
$ErrorActionPreference = 'Continue'   # qemu.ps1 sets it to Stop; the server wants Continue
New-Item -ItemType Directory -Force -Path $InstDir | Out-Null

# --- actual on-disk size (sparse file / qcow2) ---
$sig = '[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);'
$Native = Add-Type -MemberDefinition $sig -Name NexoNzQ -Namespace NexoW32Q -PassThru
function Get-OnDiskGB($p) {
    if (-not (Test-Path $p)) { return 0 }
    $h = 0; $l = $Native::GetCompressedFileSizeW($p, [ref]$h)
    return [math]::Round(([uint64]$h * 4294967296 + $l) / 1GB, 2)
}

# this host's LAN IPv4 (so the UI can build addresses reachable from other PCs)
function Get-HostIp {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -in 'Dhcp','Manual' } |
            Sort-Object { $_.IPAddress -notmatch '^(192\.168\.|10\.|172\.)' } |
            Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    } catch { }
    return '127.0.0.1'
}
$HostIp = Get-HostIp

# --- instance inventory ---
function Read-Instances {
    $list = @()
    if (Test-Path $InstDir) {
        foreach ($d in Get-ChildItem $InstDir -Directory -ErrorAction SilentlyContinue) {
            $meta = Join-Path $d.FullName 'instance.json'
            if (Test-Path $meta) { try { $list += (Get-Content $meta -Raw | ConvertFrom-Json) } catch {} }
        }
    }
    return $list
}

# --- live memory for a running VM (its QEMU process working set) ---
function Get-VmMem($name) {
    $pr = Get-VmProcess -Name "nexo-$name"
    if (-not $pr) { return $null }
    try {
        $p = Get-Process -Id $pr.ProcessId -ErrorAction Stop
        return ('{0} MB' -f [math]::Round($p.WorkingSet64 / 1MB, 0))
    } catch { return $null }
}

function Get-InstancesPayload {
    $items = @()
    foreach ($i in Read-Instances) {
        $running = Test-VmRunning -Name "nexo-$($i.name)"
        $disk = Get-OnDiskGB (Join-Path $InstDir "$($i.name)\disk.qcow2")
        $status = $i.status
        if ($status -ne 'provisioning') { $status = if ($running) { 'running' } else { 'stopped' } }
        $mem = if ($running) { Get-VmMem $i.name } else { $null }
        $items += [pscustomobject]@{
            name=$i.name; label=$i.label; status=$status; source=$i.source; os=$i.os
            created=$i.created; ram=$i.ram; cpu=$i.cpu
            web=$i.web; rdp=$i.rdp; mcp=$i.mcp; mcpKey=$i.mcpKey
            cpuLive='-'; memLive= if ($mem) { $mem } else { '-' }; diskGB=$disk
        }
    }
    return ,$items
}

function Get-Overview {
    $insts = @(Get-InstancesPayload)
    $running = @($insts | Where-Object { $_.status -eq 'running' }).Count
    $prov    = @($insts | Where-Object { $_.status -eq 'provisioning' }).Count
    $diskSum = 0; foreach ($x in $insts) { $diskSum += [double]$x.diskGB }
    $baseDisk = Get-OnDiskGB $BaseDisk
    $cs = Get-CimInstance Win32_ComputerSystem
    $avail = 0
    try { $avail = [math]::Round((Get-Counter '\Memory\Available MBytes' -EA SilentlyContinue).CounterSamples[0].CookedValue/1024,1) } catch {}
    # engine health: WHPX feature enabled + QEMU present (mapped to the UI's "dockerUp" flag)
    $engineUp = $false
    try {
        $whp = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue
        $engineUp = (($whp -and $whp.State -eq 'Enabled') -and [bool](Find-QemuExe))
    } catch {}
    return [pscustomobject]@{
        total=@($insts).Count; running=$running; provisioning=$prov
        diskSumGB=[math]::Round(($diskSum + $baseDisk), 2); baseDiskGB=$baseDisk
        hostRamGB=[math]::Round($cs.TotalPhysicalMemory/1GB,1); hostRamFreeGB=$avail
        hostCpu=(Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        hostThreads=(Get-CimInstance Win32_Processor | Select-Object -First 1).NumberOfLogicalProcessors
        dockerUp=$engineUp; engine='qemu'; baseReady=(Test-Path $BaseDisk); hostIp=$HostIp
    }
}

# --- create instance (launches the clone worker in the background) ---
function New-Instance($body) {
    $name = ($body.name -replace '[^a-zA-Z0-9\-]', '').ToLower()
    if (-not $name) { throw 'Invalid name.' }
    if (Test-Path (Join-Path $InstDir $name)) { throw "An instance '$name' already exists." }
    if (-not (Test-Path $BaseDisk)) { throw 'The base does not exist yet (run install.bat first).' }

    $used = @(Read-Instances | ForEach-Object { $_.slot })
    $slot = 1; while ($used -contains $slot) { $slot++ }
    $ports = Get-VmPorts -Slot $slot
    $key = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')

    $dir = Join-Path $InstDir $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $meta = [pscustomobject]@{
        name=$name; label=$body.label; slot=$slot
        source=($body.source|ForEach-Object{if($_){$_}else{'base'}})
        os='Windows 10 Pro'; created=(Get-Date -Format 'yyyy-MM-dd HH:mm')
        ram=($body.ram|ForEach-Object{if($_){$_}else{'4G'}})
        cpu=($body.cpu|ForEach-Object{if($_){$_}else{'2'}})
        web=$ports.VncPort; rdp=$ports.RdpPort; mcp=$ports.McpPort; mcpKey=$key; status='provisioning'
    }
    $meta | ConvertTo-Json | Set-Content (Join-Path $dir 'instance.json') -Encoding utf8

    $srcDisk = if ($meta.source -eq 'base') { $BaseDisk } else { Join-Path $InstDir "$($meta.source)\disk.qcow2" }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$CloneWorker,
        '-Name',$name,'-SourceDisk',$srcDisk,'-Root',$Root
    )
    return $meta
}

# --- start / stop / restart / delete a VM ---
function Invoke-Vm($name, $action) {
    $dir  = Join-Path $InstDir $name
    $meta = Join-Path $dir 'instance.json'
    if (-not (Test-Path $meta)) { throw "Instance '$name' does not exist." }
    $i = Get-Content $meta -Raw | ConvertFrom-Json
    $slot  = [int]$i.slot
    $ports = Get-VmPorts -Slot $slot
    $disk  = Join-Path $dir 'disk.qcow2'
    $cfg   = Join-Path $dir 'config.iso'
    $pidF  = Join-Path $dir 'vm.pid'

    function Start-One {
        if (Test-VmRunning -Name "nexo-$name") { return }
        $vmArgs = Get-VmArgs -Name "nexo-$name" -DiskPath $disk -Ram $i.ram -Cores ([int]$i.cpu) -Slot $slot -ConfigIso $cfg
        Start-Vm -VmArgs $vmArgs -PidFile $pidF | Out-Null
    }
    function Stop-One {
        $procId = 0
        $pr = Get-VmProcess -Name "nexo-$name"
        if ($pr) { $procId = [int]$pr.ProcessId }
        Stop-Vm -MonPort $ports.MonPort -ProcessId $procId | Out-Null
    }

    switch ($action) {
        'start'   { Start-One }
        'stop'    { Stop-One }
        'restart' { Stop-One; Start-Sleep -Seconds 3; Start-One }
        'delete'  { Stop-One; Start-Sleep -Seconds 2; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ============================================================
#  HTTP server (identical scaffolding to the Docker backend)
# ============================================================
$mime = @{ '.html'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.js'='application/javascript; charset=utf-8'; '.png'='image/png'; '.svg'='image/svg+xml; charset=utf-8'; '.ico'='image/x-icon'; '.json'='application/json; charset=utf-8' }

$listener = $null; $activePort = 0
# HttpListener needs "+" (all interfaces) rather than the literal 0.0.0.0; requires elevation
$prefixHost = if ($BindHost -in '0.0.0.0', '+', '*') { '+' } else { $BindHost }
foreach ($p in $Port..($Port + 15)) {
    try {
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://${prefixHost}:$p/")
        $l.Start(); $listener = $l; $activePort = $p; break
    } catch { try { $l.Close() } catch {} }
}
if (-not $listener) { throw "No free port between $Port and $($Port+15)." }
# advertise a LAN-reachable address (the host IP), not "+"
$advertHost = if ($prefixHost -eq '+') { $HostIp } else { $BindHost }
$url = "http://${advertHost}:$activePort/"
Set-Content -Path (Join-Path $Nexo 'active.url') -Value $url -Encoding ascii -NoNewline
Write-Host "NexoGate (QEMU engine) running at $url  (reachable from other PCs on the LAN)" -ForegroundColor Cyan

function Send-Json($ctx, $obj, $code = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 6
    if ([string]::IsNullOrEmpty($json)) { $json = if ($obj -is [array]) { '[]' } else { '{}' } }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}
function Send-File($ctx, $path) {
    $ext = [IO.Path]::GetExtension($path).ToLower()
    $bytes = [IO.File]::ReadAllBytes($path)
    $ctx.Response.ContentType = if ($mime[$ext]) { $mime[$ext] } else { 'application/octet-stream' }
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $req = $ctx.Request
        $path = $req.Url.LocalPath
        $method = $req.HttpMethod

        # transfer is not available on the QEMU engine yet (no \\host.lan share)
        if ($path -eq '/api/upload' -and $method -eq 'POST') {
            Send-Json $ctx @{ error = 'File transfer is not available on the Windows 10 (QEMU) engine yet. Use RDP or the MCP PowerShell tool to move files for now.' } 400
            continue
        }

        $body = $null
        if ($method -eq 'POST' -and $req.HasEntityBody) {
            $reader = [IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
            $raw = $reader.ReadToEnd(); $reader.Close()
            if ($raw) { try { $body = $raw | ConvertFrom-Json } catch { $body = $null } }
        }

        if ($path -eq '/api/overview') { Send-Json $ctx (Get-Overview); continue }
        elseif ($path -eq '/api/instances' -and $method -eq 'GET') { Send-Json $ctx (Get-InstancesPayload); continue }
        elseif ($path -eq '/api/instances' -and $method -eq 'POST') {
            try { Send-Json $ctx (New-Instance $body) } catch { Send-Json $ctx @{ error = "$_" } 400 }; continue
        }
        elseif ($path -eq '/api/files' -and $method -eq 'GET') { Send-Json $ctx (,@()); continue }
        elseif ($path -eq '/api/rdp' -and $method -eq 'GET') {
            $n = $req.QueryString['instance']
            $meta = Join-Path $InstDir "$n\instance.json"
            if ($n -and (Test-Path $meta)) {
                $i = Get-Content $meta -Raw | ConvertFrom-Json
                $rdp = @(
                    "full address:s:$($HostIp):$($i.rdp)",
                    'username:s:Docker',
                    'prompt for credentials:i:0',
                    'screen mode id:i:1', 'desktopwidth:i:1280', 'desktopheight:i:720',
                    'authentication level:i:0', 'negotiate security layer:i:1', 'enablecredsspsupport:i:0'
                ) -join "`r`n"
                $bytes = [Text.Encoding]::ASCII.GetBytes($rdp)
                $ctx.Response.ContentType = 'application/x-rdp'
                $ctx.Response.AddHeader('Content-Disposition', "attachment; filename=""nexo-$n.rdp""")
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.Close()
            } else { $ctx.Response.StatusCode = 404; $ctx.Response.Close() }
            continue
        }
        elseif ($path -match '^/api/instances/([a-z0-9\-]+)/(start|stop|restart|delete)$' -and $method -eq 'POST') {
            $n = $Matches[1]; $a = $Matches[2]
            try { Invoke-Vm $n $a; Send-Json $ctx @{ ok=$true; action=$a } }
            catch { Send-Json $ctx @{ error="$_" } 400 }; continue
        }
        elseif ($path -eq '/api/shutdown' -and $method -eq 'POST') {
            Send-Json $ctx @{ ok=$true }; $listener.Stop(); break
        }

        # static files
        $rel = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
        $file = Join-Path $Www $rel
        if ((Test-Path $file) -and ((Resolve-Path $file).Path).StartsWith((Resolve-Path $Www).Path)) {
            Send-File $ctx $file
        } else { $ctx.Response.StatusCode = 404; $ctx.Response.Close() }
    } catch {
        try {
            $msg = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
            $b = [Text.Encoding]::UTF8.GetBytes($msg)
            $ctx.Response.StatusCode = 500
            $ctx.Response.ContentType = 'text/plain; charset=utf-8'
            $ctx.Response.OutputStream.Write($b, 0, $b.Length)
            $ctx.Response.Close()
        } catch {}
    }
}
$listener.Close()
