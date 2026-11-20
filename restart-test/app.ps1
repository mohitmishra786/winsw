# Wrapped test application. On the first start it runs the self-restart command
# from command.txt and logs the result; afterwards it only logs that it started.
$base = $PSScriptRoot
$log = Join-Path $base 'events.log'
function L([string]$m) { Add-Content -Path $log -Value ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m) }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$label = (whoami /groups /fo csv | ConvertFrom-Csv | Where-Object { $_.'Group Name' -like 'Mandatory Label*' }).'Group Name'
$privs = (whoami /priv /fo csv | ConvertFrom-Csv | ForEach-Object { $_.'Privilege Name' }) -join ','
L "START pid=$PID user=$($id.Name) interactive=$([Environment]::UserInteractive) label=$label privs=$privs"

$marker = Join-Path $base 'restarted.marker'
if (-not (Test-Path $marker)) {
    New-Item -ItemType File -Path $marker | Out-Null
    Start-Sleep -Seconds 5
    $cmd = @((Get-Content (Join-Path $base 'command.txt') -Raw).Trim() -split ' ')
    L "RUN $env:WINSW_EXECUTABLE $($cmd -join ' ')"
    $out = & $env:WINSW_EXECUTABLE @cmd 2>&1 | Out-String
    L "EXIT $LASTEXITCODE"
    L "OUTPUT`n$out"
}
while ($true) { Start-Sleep -Seconds 1 }
