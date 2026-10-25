# BeeNote - set up BeeNote's own job runner in the Windows 11 VM, once, in
# an administrator PowerShell (omarchy-windows-vm launch):
#   powershell -ExecutionPolicy Bypass -File \\host.lan\Data\beenote-run\setup.ps1
# BeeModel has a runner of its own in bee-run; this one lives apart
# (beenote-run on the share, C:\beenote-run in the guest, the task
# 'BeeNote runner') so the two never pick up each other's jobs. It turns
# off the network-file caches, so files the host writes show at once,
# copies boot.ps1 to C:\beenote-run and registers a task that starts it,
# hidden, at every log-on, and starts it now. boot.ps1 runs whatever
# runner the host publishes, so later runners need no new setup.
$share = '\\host.lan\Data\beenote-run'
$local = 'C:\beenote-run'
Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileInfoCacheLifetime 0 `
    -FileNotFoundCacheLifetime 0 -Force
New-Item -ItemType Directory -Force $local | Out-Null
Copy-Item "$share\boot.ps1" "$local\boot.ps1" -Force
Stop-ScheduledTask -TaskName 'BeeNote runner' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'beenote-run\\(runner|boot)' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $local\boot.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'BeeNote runner' -Action $action -Trigger $trigger `
    -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'BeeNote runner'
Write-Host "BeeNote runner: registered and started ($((Get-ScheduledTask 'BeeNote runner').Actions.Arguments))"
