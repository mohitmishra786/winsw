# Runs the Jenkins controller as a WinSW service with the jenkins.xml shipped in
# jenkins.war, triggers a restart from the Jenkins UI endpoint, and reports
# whether the service came back.
param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $War,
    [string] $Exe = '',  # empty: use the jenkins.exe bundled in the war
    [ValidateSet('System', 'User')] [string] $Account = 'User',
    [switch] $Privs
)
$ErrorActionPreference = 'Stop'
$dir = "C:\jk\$Name"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item $War "$dir\jenkins.war"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($War)
foreach ($e in $zip.Entries | Where-Object { $_.FullName -in 'windows-service/jenkins.exe', 'windows-service/jenkins.xml' }) {
    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, "$dir\$($e.Name)", $true)
}
$zip.Dispose()
if ($Exe) { Copy-Item $Exe "$dir\jenkins.exe" -Force }
Write-Host "jenkins.exe version: $((Get-Item "$dir\jenkins.exe").VersionInfo.ProductVersion)"

$java = Join-Path $env:JAVA_HOME_21_X64 'bin\java.exe'
$xml = Get-Content "$dir\jenkins.xml" -Raw
$xml = $xml.Replace('<executable>java</executable>', "<executable>$java</executable>")
$xml = $xml.Replace('-Xrs -Xmx256m', '-Xrs -Xmx512m -Djenkins.install.runSetupWizard=false')
if ($Account -eq 'User') {
    $xml = $xml.Replace('</service>', "  <serviceaccount><domain>.</domain><user>rtuser</user><password>$env:RT_PASSWORD</password><allowservicelogon>true</allowservicelogon></serviceaccount>`n</service>")
}
Set-Content -Path "$dir\jenkins.xml" -Value $xml
icacls $dir /grant 'rtuser:(OI)(CI)M' | Out-Null
icacls $env:JAVA_HOME_21_X64 /grant 'rtuser:(OI)(CI)RX' /T /Q | Out-Null

& "$dir\jenkins.exe" install 2>&1 | Out-Host
if ($Privs) { sc.exe privs jenkins SeChangeNotifyPrivilege | Out-Host }
if ($Account -eq 'User') {
    $sid = ([Security.Principal.NTAccount]'rtuser').Translate([Security.Principal.SecurityIdentifier]).Value
    sc.exe sdset jenkins "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;CCLCSWRPWPDTLOCRRC;;;$sid)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)" | Out-Host
}
sc.exe start jenkins | Out-Null

function Wait-Up([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:8080/api/json' -TimeoutSec 5; if ($r.StatusCode -eq 200) { return $true } } catch { }
        Start-Sleep -Seconds 3
    }
    return $false
}
function Up-Count { if (Test-Path "$dir\jenkins.err.log") { @(Select-String -Path "$dir\jenkins.err.log" -Pattern 'Jenkins is fully up and running').Count } else { 0 } }

$up1 = Wait-Up 240
Write-Host "first start up: $up1, fully-up lines: $(Up-Count)"
$restart = 'not attempted'
if ($up1) {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $crumb = Invoke-RestMethod -Uri 'http://localhost:8080/crumbIssuer/api/json' -WebSession $session
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'http://localhost:8080/restart' -WebSession $session -Headers @{ $crumb.crumbRequestField = $crumb.crumb } -MaximumRedirection 0 -ErrorAction SilentlyContinue
        $restart = "HTTP $($r.StatusCode)"
    } catch { $restart = "request error: $($_.Exception.Message)" }
    Start-Sleep -Seconds 20
}
$up2 = Wait-Up 240
$count = Up-Count
$state = (Get-Service jenkins).Status
Write-Host "restart request: $restart; up after restart: $up2; fully-up lines: $count; service: $state"
Write-Host '== jenkins.wrapper.log'; Get-Content "$dir\jenkins.wrapper.log" -ErrorAction SilentlyContinue | Out-Host
Write-Host '== jenkins.err.log (restart-related lines)'
Select-String -Path "$dir\jenkins.err.log" -Pattern 'restart|Restart|Exception|FATAL|Access|fully up|at hudson|at winsw|at WinSW|\[CRLF\]' -ErrorAction SilentlyContinue | ForEach-Object { $_.Line } | Out-Host
"| $Name | $(if ($Exe) { [IO.Path]::GetFileName($Exe) } else { 'bundled jenkins.exe' }) | $Account | $restart | $count | $state |" | Add-Content $env:GITHUB_STEP_SUMMARY

sc.exe stop jenkins | Out-Null
Start-Sleep -Seconds 10
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$dir*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
sc.exe delete jenkins | Out-Null
Start-Sleep -Seconds 3
