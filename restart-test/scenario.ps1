# Installs a WinSW service that wraps app.ps1, lets it run its self-restart
# command once, then prints the logs and service state and removes the service.
param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Exe,
    [ValidateSet('System', 'User')] [string] $Account = 'User',
    # full: user may stop and start; nostart: user may stop only; default: no sdset
    [ValidateSet('full', 'nostart', 'default')] [string] $Dacl = 'full',
    [string] $Command = 'restart!',
    [switch] $Privs,
    [int] $WaitSeconds = 60
)
$ErrorActionPreference = 'Stop'
$svc = "rt-$Name"
$dir = "C:\rt\$Name"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item $Exe "$dir\svc.exe"
Copy-Item "$PSScriptRoot\app.ps1" $dir
Set-Content -Path "$dir\command.txt" -Value $Command -NoNewline

$acct = ''
if ($Account -eq 'User') {
    $acct = "<serviceaccount><domain>.</domain><user>rtuser</user><password>$env:RT_PASSWORD</password><allowservicelogon>true</allowservicelogon></serviceaccount>"
}
@"
<service>
  <id>$svc</id>
  <name>$svc</name>
  <description>restart! test</description>
  <executable>powershell.exe</executable>
  <arguments>-NoProfile -ExecutionPolicy Bypass -File "%BASE%\app.ps1"</arguments>
  <logpath>%BASE%\logs</logpath>
  <log mode="append"/>
  $acct
</service>
"@ | Set-Content -Path "$dir\svc.xml"

icacls $dir /grant 'rtuser:(OI)(CI)M' | Out-Null

Write-Host "== install"
& "$dir\svc.exe" install 2>&1 | Out-Host
if ($Privs) { sc.exe privs $svc SeChangeNotifyPrivilege | Out-Host }
if ($Dacl -ne 'default') {
    $sid = ([Security.Principal.NTAccount]'rtuser').Translate([Security.Principal.SecurityIdentifier]).Value
    $userAce = if ($Dacl -eq 'full') { 'CCLCSWRPWPDTLOCRRC' } else { 'CCLCSWWPDTLOCRRC' }
    $sddl = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;$userAce;;;$sid)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)"
    sc.exe sdset $svc $sddl | Out-Host
}
sc.exe sdshow $svc | Out-Host
sc.exe qprivs $svc | Out-Host

Write-Host "== start"
sc.exe start $svc | Out-Null
Start-Sleep -Seconds $WaitSeconds

$events = if (Test-Path "$dir\events.log") { Get-Content "$dir\events.log" } else { @() }
$starts = @($events | Where-Object { $_ -match ' START ' }).Count
$state = (Get-Service $svc).Status
Write-Host "== events.log"; $events | Out-Host
Get-ChildItem "$dir\logs" -Filter *.wrapper.log -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "== $($_.Name)"; Get-Content $_.FullName | Out-Host }
Get-ChildItem "$dir\logs" -Filter *.err.log -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "== $($_.Name)"; Get-Content $_.FullName | Out-Host }
Write-Host "== result: starts=$starts state=$state"

$exit = ($events | Where-Object { $_ -match ' EXIT ' } | Select-Object -First 1) -replace '^.* EXIT ', ''
"| $Name | $([IO.Path]::GetFileName($Exe)) | $Account | $Dacl | $Privs | ``$Command`` | $exit | $starts | $state |" | Add-Content $env:GITHUB_STEP_SUMMARY

Write-Host "== cleanup"
sc.exe stop $svc | Out-Null
Start-Sleep -Seconds 5
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$dir*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
sc.exe delete $svc | Out-Null
