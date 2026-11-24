param([string]$Exe, [string]$Dir, [int]$Count)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Dir | Out-Null
Copy-Item $Exe "$Dir\race.exe"
@"
<service>
  <id>race</id>
  <name>race</name>
  <executable>ping.exe</executable>
  <arguments>-n 100000 127.0.0.1</arguments>
  <log mode="none"/>
</service>
"@ | Set-Content "$Dir\race.xml"
& "$Dir\race.exe" install | Out-Null
for ($i = 0; $i -lt $Count; $i++) {
  & "$Dir\race.exe" start | Out-Null
  Start-Sleep -Milliseconds 300
  & "$Dir\race.exe" stop | Out-Null
}
& "$Dir\race.exe" uninstall | Out-Null
$hits = @(Select-String -Path "$Dir\race.wrapper.log" -Pattern 'Failed to stop service' ).Count
Select-String -Path "$Dir\race.wrapper.log" -Pattern 'Exception:' | Group-Object { $_.Line -replace '^.*?(\w+Exception: [^\r\n]*).*$','$1' } | ForEach-Object { "$($_.Count)x $($_.Name)" }
"RESULT $hits/$Count stops failed"
