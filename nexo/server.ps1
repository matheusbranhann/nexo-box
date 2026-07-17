# ============================================================
#  NexoGate - instance manager backend (pure PowerShell)
#  Native HTTP server (HttpListener). Zero dependencies.
#  REST API + serves the UI. Binds only to 127.0.0.1.
# ============================================================
param(
    [int]$Port = 7099,
    [string]$BindHost = '127.0.0.1'
)
# Continue (not Stop): keeps docker command stderr from becoming an exception.
# Real errors (.NET, explicit throw) are still caught by the try/catch blocks.
$ErrorActionPreference = 'Continue'
$Root       = Split-Path -Parent $PSScriptRoot          # E:\projetos\box
$Nexo       = $PSScriptRoot                              # E:\projetos\box\nexo
$Www        = Join-Path $Nexo 'www'
$InstDir    = Join-Path $Root 'instances'
$BaseStorage= Join-Path $Root 'storage\data.qcow2'
$CloneWorker= Join-Path $Nexo 'clone-instance.ps1'
New-Item -ItemType Directory -Force -Path $InstDir | Out-Null

# --- docker on PATH ---
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $env:Path = "$env:ProgramFiles\Docker\Docker\resources\bin;" + $env:Path
}

# --- actual on-disk size (sparse file / qcow2) ---
$sig = '[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);'
$Native = Add-Type -MemberDefinition $sig -Name NexoNz -Namespace NexoW32 -PassThru
function Get-OnDiskGB($p) {
    if (-not (Test-Path $p)) { return 0 }
    $h = 0; $l = $Native::GetCompressedFileSizeW($p, [ref]$h)
    return [math]::Round(([uint64]$h * 4294967296 + $l) / 1GB, 2)
}

# --- port allocation per slot (the base uses 8006/8000/3389) ---
function Get-Ports($slot) {
    return [pscustomobject]@{ web = 8100 + $slot; rdp = 8200 + $slot; mcp = 8300 + $slot }
}

# --- instance inventory ---
function Read-Instances {
    $list = @()
    if (Test-Path $InstDir) {
        foreach ($d in Get-ChildItem $InstDir -Directory -ErrorAction SilentlyContinue) {
            $meta = Join-Path $d.FullName 'instance.json'
            if (Test-Path $meta) {
                try { $list += (Get-Content $meta -Raw | ConvertFrom-Json) } catch {}
            }
        }
    }
    return $list
}

# --- live stats for all containers at once ---
function Get-LiveStats {
    $map = @{}
    try {
        $raw = docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>$null
        foreach ($line in $raw) {
            $p = $line -split '\|'
            if ($p.Count -ge 3) {
                $mem = ($p[2] -split '/')[0].Trim()
                $map[$p[0]] = [pscustomobject]@{ cpu = $p[1].Trim(); mem = $mem }
            }
        }
    } catch {}
    return $map
}

# --- container status (running/exited/absent) ---
function Get-ContainerState($name) {
    try {
        $s = docker inspect -f '{{.State.Status}}' $name 2>$null
        if ($LASTEXITCODE -eq 0 -and $s) { return $s.Trim() }
    } catch {}
    return 'absent'
}

function Get-InstancesPayload {
    $stats = Get-LiveStats
    $items = @()
    foreach ($i in Read-Instances) {
        $cname = "nexo-$($i.name)"
        $state = Get-ContainerState $cname
        $st = $stats[$cname]
        $disk = Get-OnDiskGB (Join-Path $InstDir "$($i.name)\storage\data.qcow2")
        $status = $i.status
        if ($status -ne 'provisioning') {
            # derive from the real state; a running container clears a spurious 'error'
            $status = switch ($state) {
                'running' { 'running' }
                'exited'  { 'stopped' }
                'created' { 'stopped' }
                default   { if ($i.status -eq 'error') { 'error' } else { 'stopped' } }
            }
        }
        $items += [pscustomobject]@{
            name    = $i.name
            label   = $i.label
            status  = $status
            source  = $i.source
            os      = $i.os
            created = $i.created
            ram     = $i.ram
            cpu     = $i.cpu
            web     = $i.web
            rdp     = $i.rdp
            mcp     = $i.mcp
            mcpKey  = $i.mcpKey
            cpuLive = if ($st) { $st.cpu } else { '-' }
            memLive = if ($st) { $st.mem } else { '-' }
            diskGB  = $disk
        }
    }
    return ,$items
}

function Get-Overview {
    $insts = @(Get-InstancesPayload)
    $running = @($insts | Where-Object { $_.status -eq 'running' }).Count
    $prov    = @($insts | Where-Object { $_.status -eq 'provisioning' }).Count
    $diskSum = 0; foreach ($x in $insts) { $diskSum += [double]$x.diskGB }  # robust for zero instances
    $baseDisk = Get-OnDiskGB $BaseStorage
    $cs = Get-CimInstance Win32_ComputerSystem
    $avail = 0
    try { $avail = [math]::Round((Get-Counter '\Memory\Available MBytes' -EA SilentlyContinue).CounterSamples[0].CookedValue/1024,1) } catch {}
    $dockerUp = $false
    try { docker info *> $null; $dockerUp = ($LASTEXITCODE -eq 0) } catch {}
    return [pscustomobject]@{
        total     = @($insts).Count
        running   = $running
        provisioning = $prov
        diskSumGB = [math]::Round(($diskSum + $baseDisk), 2)
        baseDiskGB= $baseDisk
        hostRamGB = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
        hostRamFreeGB = $avail
        hostCpu   = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        hostThreads = (Get-CimInstance Win32_Processor | Select-Object -First 1).NumberOfLogicalProcessors
        dockerUp  = $dockerUp
        baseReady = (Test-Path $BaseStorage)
    }
}

# --- create instance (launches the clone worker in the background) ---
function New-Instance($body) {
    $name = ($body.name -replace '[^a-zA-Z0-9\-]', '').ToLower()
    if (-not $name) { throw 'Invalid name.' }
    if (Test-Path (Join-Path $InstDir $name)) { throw "An instance '$name' already exists." }
    if (-not (Test-Path $BaseStorage)) { throw 'The base does not exist yet (install the box first).' }

    # free slot
    $used = @(Read-Instances | ForEach-Object { $_.slot })
    $slot = 1; while ($used -contains $slot) { $slot++ }
    $ports = Get-Ports $slot
    $key = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')

    $dir = Join-Path $InstDir $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $meta = [pscustomobject]@{
        name=$name; label=$body.label; slot=$slot; source=($body.source|ForEach-Object{if($_){$_}else{'base'}})
        os='Windows 10 Pro'; created=(Get-Date -Format 'yyyy-MM-dd HH:mm')
        ram=($body.ram|ForEach-Object{if($_){$_}else{'4G'}}); cpu=($body.cpu|ForEach-Object{if($_){$_}else{'2'}})
        cpus=($body.cpus|ForEach-Object{if($_){$_}else{'2.0'}})
        web=$ports.web; rdp=$ports.rdp; mcp=$ports.mcp; mcpKey=$key; status='provisioning'
    }
    $meta | ConvertTo-Json | Set-Content (Join-Path $dir 'instance.json') -Encoding utf8

    # detached worker: copies the qcow2 + generates compose/.env + brings it up
    $src = if ($meta.source -eq 'base') { $Root } else { Join-Path $InstDir $meta.source }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$CloneWorker,
        '-Name',$name,'-SourceDir',$src,'-Root',$Root
    )
    return $meta
}

function Invoke-Compose($name, $action) {
    $dir = Join-Path $InstDir $name
    $compose = Join-Path $dir 'compose.yml'
    if (-not (Test-Path $compose)) { throw "compose.yml for instance '$name' does not exist." }
    Push-Location $dir
    try {
        wsl -d docker-desktop -u root -e sh -c 'modprobe kvm_amd 2>/dev/null; modprobe kvm_intel 2>/dev/null; true' 2>$null
        switch ($action) {
            'start'   { docker compose up -d 2>&1 | Out-Null }
            'stop'    { docker compose stop 2>&1 | Out-Null }
            'restart' { docker compose restart 2>&1 | Out-Null }
            'delete'  { docker compose down -v 2>&1 | Out-Null }
        }
    } finally { Pop-Location }
    if ($action -eq 'delete') { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# shared folder for a box (or the base); files here show up as \\host.lan\Data in the guest
function Get-SharedDir($name) {
    if (-not $name -or $name -eq 'base') { return (Join-Path $Root 'shared') }
    $safe = ($name -replace '[^a-zA-Z0-9\-]', '')
    return (Join-Path $InstDir "$safe\shared")
}
function Get-SharedFiles($name) {
    $dir = Get-SharedDir $name
    $files = @()
    if (Test-Path $dir) {
        Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'mcp.key' } | ForEach-Object {
            $files += [pscustomobject]@{ name = $_.Name; sizeKB = [math]::Round($_.Length / 1KB, 1) }
        }
    }
    return ,$files
}

# ============================================================
#  HTTP server
# ============================================================
$mime = @{ '.html'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.js'='application/javascript; charset=utf-8'; '.png'='image/png'; '.svg'='image/svg+xml; charset=utf-8'; '.ico'='image/x-icon'; '.json'='application/json; charset=utf-8' }

# try a range of ports (avoids conflicts with AnyDesk/etc.)
$listener = $null
$activePort = 0
foreach ($p in $Port..($Port + 15)) {
    try {
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://${BindHost}:$p/")
        $l.Start()
        $listener = $l; $activePort = $p; break
    } catch { try { $l.Close() } catch {} }
}
if (-not $listener) { throw "No free port between $Port and $($Port+15)." }
$url = "http://${BindHost}:$activePort/"
Set-Content -Path (Join-Path $Nexo 'active.url') -Value $url -Encoding ascii -NoNewline
Write-Host "NexoGate running at $url  (close the window to stop)" -ForegroundColor Cyan

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

        # ---- file upload from the browser (raw body; must run BEFORE the JSON body read) ----
        if ($path -eq '/api/upload' -and $method -eq 'POST') {
            try {
                $inst  = $req.QueryString['instance']
                $fname = [IO.Path]::GetFileName([string]$req.QueryString['name'])
                if (-not $fname) { throw 'Missing file name.' }
                $dir = Get-SharedDir $inst
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $dest = Join-Path $dir $fname
                $fs = [IO.File]::Create($dest)
                try { $req.InputStream.CopyTo($fs) } finally { $fs.Close() }
                $size = (Get-Item $dest).Length
                Send-Json $ctx @{ ok = $true; name = $fname; sizeKB = [math]::Round($size / 1KB, 1) }
            } catch { Send-Json $ctx @{ error = "$_" } 400 }
            continue
        }

        $body = $null
        if ($method -eq 'POST' -and $req.HasEntityBody) {
            $reader = [IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
            $raw = $reader.ReadToEnd(); $reader.Close()
            if ($raw) { try { $body = $raw | ConvertFrom-Json } catch { $body = $null } }
        }

        # ---- API ----
        if ($path -eq '/api/overview') { Send-Json $ctx (Get-Overview); continue }
        elseif ($path -eq '/api/instances' -and $method -eq 'GET') { Send-Json $ctx (Get-InstancesPayload); continue }
        elseif ($path -eq '/api/instances' -and $method -eq 'POST') {
            try { Send-Json $ctx (New-Instance $body) } catch { Send-Json $ctx @{ error = "$_" } 400 }; continue
        }
        elseif ($path -eq '/api/files' -and $method -eq 'GET') {
            Send-Json $ctx (Get-SharedFiles $req.QueryString['instance']); continue
        }
        elseif ($path -eq '/api/download' -and $method -eq 'GET') {
            $inst = $req.QueryString['instance']; $fname = [IO.Path]::GetFileName([string]$req.QueryString['name'])
            $file = Join-Path (Get-SharedDir $inst) $fname
            if ($fname -and (Test-Path $file)) {
                $fs = [IO.File]::OpenRead($file)
                $ctx.Response.ContentType = 'application/octet-stream'
                $ctx.Response.ContentLength64 = $fs.Length
                $ctx.Response.AddHeader('Content-Disposition', "attachment; filename=""$fname""")
                try { $fs.CopyTo($ctx.Response.OutputStream) } finally { $fs.Close() }
                $ctx.Response.Close()
            } else { $ctx.Response.StatusCode = 404; $ctx.Response.Close() }
            continue
        }
        elseif ($path -match '^/api/instances/([a-z0-9\-]+)/(start|stop|restart|delete)$' -and $method -eq 'POST') {
            $n = $Matches[1]; $a = $Matches[2]
            try { Invoke-Compose $n $a; Send-Json $ctx @{ ok=$true; action=$a } }
            catch { Send-Json $ctx @{ error="$_" } 400 }; continue
        }
        elseif ($path -eq '/api/shutdown' -and $method -eq 'POST') {
            Send-Json $ctx @{ ok=$true }; $listener.Stop(); break
        }

        # ---- static files ----
        $rel = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
        $file = Join-Path $Www $rel
        if ((Test-Path $file) -and ((Resolve-Path $file).Path).StartsWith((Resolve-Path $Www).Path)) {
            Send-File $ctx $file
        } else {
            $ctx.Response.StatusCode = 404; $ctx.Response.Close()
        }
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
