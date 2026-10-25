# BeeNote - the job runner in the Windows 11 VM, run by boot.ps1 (which
# setup.ps1 starts at every log-on). It watches beenote-run on the shared
# folder (~/Windows on the host, \\host.lan\Data in the guest) for
# <id>.cmd, copies beenote-run\bin\ (the build and the test drivers) and
# the job to C:\beenote-run, runs the job there with cmd.exe (killed after
# <id>.limit seconds, default 900), and writes back <id>.out (stdout and
# stderr, as bytes) and then <id>.rc (the exit code; the host waits for
# it). A local copy, because Windows warns before running a program from a
# network folder. The host publishes it as runner-<hash>.ps1, a new name
# for every version, because the guest's network-file cache can keep
# serving a file the host overwrote; it ends when its file is gone from the
# share, and boot.ps1 starts the new one. Steps and errors go to
# beenote-run\runner.log. tools/winvm-run.sh is the host's side.
$ErrorActionPreference = 'Stop'          # (every failure reaches the log)
$share = '\\host.lan\Data\beenote-run'
$local = 'C:\beenote-run'
$self = Split-Path -Leaf $PSCommandPath
function Log($m) { Add-Content -Path "$share\runner.log" -Value "$(Get-Date -Format o) $m" -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $local | Out-Null
$os = Get-CimInstance Win32_OperatingSystem
Log "$self up: $($os.Caption) $($os.Version)"
while ($true) {
    try {
        Set-Content -Path "$share\runner.alive" -Encoding ascii `
            -Value "$self $($os.Caption) $($os.Version) $(Get-Date -Format o)"
        if (-not (Test-Path "$share\$self")) { Log "$self replaced: restarting"; exit 0 }
        foreach ($job in @(Get-ChildItem -Path $share -Filter '*.cmd' | Sort-Object Name)) {
            $id = $job.BaseName
            Log "job $id"
            $limit = 900
            if (Test-Path "$share\$id.limit") { $limit = [int](Get-Content "$share\$id.limit"); Remove-Item "$share\$id.limit" }
            if (Test-Path "$share\bin") { Copy-Item "$share\bin\*" $local -Force -Recurse }
            $cmd = "$local\$id.cmd"; $out = "$local\$id.out"
            Copy-Item $job.FullName $cmd -Force
            Remove-Item $job.FullName
            # Full paths, quoted the way cmd /c wants a whole quoted line.
            $p = Start-Process -FilePath cmd.exe -ArgumentList "/c `"`"$cmd`" > `"$out`" 2>&1`"" `
                -WorkingDirectory $local -WindowStyle Hidden -PassThru
            if ($p.WaitForExit($limit * 1000)) { $rc = $p.ExitCode }
            else { & taskkill.exe /T /F /PID $p.Id | Out-Null; $rc = 124; Log "job $id killed after $limit s" }
            if (Test-Path $out) { Copy-Item $out "$share\$id.out" -Force }
            Remove-Item $cmd, $out -ErrorAction SilentlyContinue
            Set-Content -Path "$share\$id.rc" -Value $rc -Encoding ascii
            Log "job $id rc=$rc"
        }
    } catch { Log "error: $_" }
    Start-Sleep -Milliseconds 500
}
