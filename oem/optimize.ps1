# ============================================================
#  Nexo Box - AGGRESSIVE Windows optimization from the inside
#  Safe: it does not touch installed apps, networking, the DWM or the MCP.
#  Idempotent. Writes a log to \\host.lan\Data\optimize-log.txt (= shared/).
# ============================================================
$ErrorActionPreference = 'Continue'

$logs = @('\\host.lan\Data\optimize-log.txt', 'C:\OEM\optimize-log.txt')
function Log($m){ foreach($p in $logs){ try{ Add-Content -Path $p -Value $m -Encoding utf8 -ErrorAction SilentlyContinue }catch{} } }
foreach($p in $logs){ try{ Set-Content -Path $p -Value '' -ErrorAction SilentlyContinue }catch{} }

function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024) }
Log "=== START $(Get-Date -Format 'HH:mm:ss') ==="
Log ("RAM free before: {0} MB" -f (FreeMB))

# --- HARDENING: never disable anything in this list, no matter what ---
$critical = @(
  'RpcSs','DcomLaunch','RpcEptMapper','LSM','Themes','UxSms','Dnscache','Dhcp','nsi',
  'netprofm','NlaSvc','Netman','LanmanWorkstation','LanmanServer','Winmgmt','Schedule',
  'mpssvc','BFE','CryptSvc','Wcmsvc','EventLog','ProfSvc','gpsvc','SamSs','Power','PlugPlay',
  'BrokerInfrastructure','SystemEventsBroker','CoreMessagingRegistrar','Audiosrv',
  'AudioEndpointBuilder','TrustedInstaller','msiserver','ProfSvc','Appinfo','UserManager',
  'TokenBroker','WinHttpAutoProxySvc','Dhcp','EventSystem','FontCache'
)

# --- SERVICES to disable (real background CPU/RAM savings) ---
$svcDisable = @(
  'DiagTrack','dmwappushservice','SysMain','WSearch','Spooler','Fax','WbioSrvc',
  'WMPNetworkSvc','RemoteRegistry','RetailDemo','MapsBroker','lfsvc','WalletService',
  'PhoneSvc','SEMgrSvc','TrkWks','PcaSvc','DoSvc','WerSvc','DusmSvc','WpcMonSvc',
  'diagnosticshub.standardcollector.service','XblAuthManager','XblGameSave',
  'XboxNetApiSvc','XboxGipSvc','wisvc','DiagSvc','WdiSystemHost','WdiServiceHost'
)
$done = 0
foreach($s in $svcDisable){
  if($critical -contains $s){ continue }
  try{
    $svc = Get-Service -Name $s -ErrorAction Stop
    if($svc.StartType -ne 'Disabled'){
      Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
      Set-Service  -Name $s -StartupType Disabled -ErrorAction Stop
      $done++
    }
  }catch{}
}
Log "Services disabled: $done"

# --- Windows Update: do not break servicing, just stop the background auto-update ---
try{
  Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
  New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -Type DWord -Force
}catch{}

# --- Scheduled tasks for telemetry/maintenance/scan ---
$tasks = @(
  '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
  '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
  '\Microsoft\Windows\Application Experience\StartupAppTask',
  '\Microsoft\Windows\Application Experience\PcaPatchDbTask',
  '\Microsoft\Windows\Autochk\Proxy',
  '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
  '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
  '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
  '\Microsoft\Windows\Feedback\Siuf\DmClient',
  '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
  '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
  '\Microsoft\Windows\Maps\MapsUpdateTask',
  '\Microsoft\Windows\Maps\MapsToastTask',
  '\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance',
  '\Microsoft\Windows\Windows Defender\Windows Defender Cleanup',
  '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan',
  '\Microsoft\Windows\Windows Defender\Windows Defender Verification'
)
$td = 0
foreach($t in $tasks){
  $p = Split-Path $t; $n = Split-Path $t -Leaf
  try{ Disable-ScheduledTask -TaskPath ($p + '\') -TaskName $n -ErrorAction Stop | Out-Null; $td++ }catch{}
}
Log "Scheduled tasks disabled: $td"

# --- Registry: telemetry, suggestions, Cortana, web search, prefetch, last-access ---
function RegSet($path,$name,$val,$type='DWord'){ try{ if(-not(Test-Path $path)){ New-Item $path -Force | Out-Null }; Set-ItemProperty $path -Name $name -Value $val -Type $type -Force }catch{} }
RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
RegSet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0
RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 0
# per-user suggestions/animations/transparency (perf), without disabling the DWM
RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
RegSet 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
RegSet 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' 0 'String'
RegSet 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' 0 'String'
RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisableLastAccessUpdate' 1
Log 'Registry adjusted (telemetry/suggestions/animations/prefetch/last-access)'

# --- Defender: keep it installed, but with no background scan (real-time already off) ---
try{
  Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
  Set-MpPreference -MAPSReporting 0 -SubmitSamplesConsent 2 -DisableScanningNetworkFiles $true -ErrorAction SilentlyContinue
  Add-MpPreference -ExclusionPath 'C:\OEM' -ErrorAction SilentlyContinue
}catch{}

# --- Power: high-performance plan, no sleep/hibernation ---
try{ powercfg /setactive SCHEME_MIN 2>$null; powercfg /change standby-timeout-ac 0; powercfg /change monitor-timeout-ac 0; powercfg /hibernate off 2>$null }catch{}

# --- Disk cleanup (frees space in the qcow2 after the TRIM below) ---
$before = 0; try{ $before = (Get-PSDrive C).Used }catch{}
foreach($d in @($env:TEMP,'C:\Windows\Temp','C:\Windows\SoftwareDistribution\Download','C:\Windows\Prefetch')){
  try{ Get-ChildItem $d -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }catch{}
}
try{ Clear-RecycleBin -Force -ErrorAction SilentlyContinue }catch{}
try{ Log 'DISM StartComponentCleanup...'; & dism.exe /online /Cleanup-Image /StartComponentCleanup 2>&1 | Out-Null }catch{}

# --- Return the freed space to the host (qcow2 + DISK_DISCARD=unmap) ---
try{ Log 'Optimize-Volume ReTrim...'; Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-Null }catch{}

Log ("RAM free after: {0} MB" -f (FreeMB))
Log "=== END $(Get-Date -Format 'HH:mm:ss') ==="
Log 'DONE'
