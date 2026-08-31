# fms-assistant stop - stop the harness (:3081) and proxy (:3082) started by
# start.cmd / install.cmd. Kills whichever process LISTENS on those ports.
# ASCII-only on purpose (PS 5.1).
$ErrorActionPreference = "Stop"
foreach ($p in @("3081", "3082")) {
    $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "Stopping PID $($c.OwningProcess) ($($proc.ProcessName)) on port $p"
            Stop-Process -Id $c.OwningProcess -Force
        }
    }
}
Write-Host "Stopped. (If a node process still shows on those ports, it is not ours - check manually.)"
