# fms-assistant start - start harness + proxy from the existing install.
# Run after a reboot or a stop. First-time setup is install.cmd; this script
# does NOT reinstall anything, it only starts the two processes.
# ASCII-only on purpose (PS 5.1 reads BOM-less .ps1 as ANSI).
$ErrorActionPreference = "Stop"

$BASE_DIR = Join-Path $HOME ".fms-assistant"
$ENV_FILE = Join-Path $BASE_DIR ".env"
$HARNESS_PORT = if ($env:HARNESS_PORT) { $env:HARNESS_PORT } else { "3081" }
$PROXY_PORT   = if ($env:PROXY_PORT)   { $env:PROXY_PORT }   else { "3082" }
$BIND_HOST    = if ($env:HOST)         { $env:HOST }         else { "127.0.0.1" }

function Say([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }

if (-not (Test-Path $ENV_FILE)) {
    Write-Host "[ERROR] $ENV_FILE not found - run install.cmd first" -ForegroundColor Red
    exit 1
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] node not found on PATH" -ForegroundColor Red
    exit 1
}
if (-not (Get-Command dsh -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] dsh not installed - run install.cmd first" -ForegroundColor Red
    exit 1
}

# Ports must be free (a previous instance may still be running).
foreach ($p in @($HARNESS_PORT, $PROXY_PORT)) {
    $inUse = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        Write-Host "[ERROR] port $p already in use by PID $($inUse.OwningProcess) - run stop.cmd first" -ForegroundColor Red
        exit 1
    }
}

# Read .env into a map (PS 5.1 safe).
$envMap = @{}
Get-Content $ENV_FILE | ForEach-Object {
    if ($_ -match '^([A-Z_]+)=(.*)$') { $envMap[$matches[1]] = $matches[2] }
}

Say "Starting harness (port $HARNESS_PORT) + proxy (port $PROXY_PORT) ..."
$env:DSH_HOME = Join-Path $BASE_DIR "harness"
$env:DSH_PERMISSION_MODE = "read-only"
$env:FMS_MCP_TOKEN = $envMap["FMS_MCP_TOKEN"]
$env:FMS_WORKSPACE_DIR = $envMap["FMS_WORKSPACE_DIR"]
$env:FMS_WORKSPACE_TITLE = $envMap["FMS_WORKSPACE_TITLE"]
$dshCmd = "dsh --profile assistant --port $HARNESS_PORT --trusted-host 127.0.0.1:$PROXY_PORT"
$harness = Start-Process -FilePath $env:ComSpec `
    -ArgumentList @("/c", $dshCmd) `
    -WorkingDirectory $BASE_DIR -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $BASE_DIR "harness.log") -RedirectStandardError (Join-Path $BASE_DIR "harness.err.log")

$env:PORT = $PROXY_PORT
$env:TARGET = "http://127.0.0.1:$HARNESS_PORT"
$env:FMS_ORIGIN = $envMap["FMS_ORIGIN"]
$env:FMS_OWNER_USERNAME = $envMap["FMS_OWNER_USERNAME"]
$env:HOST = $BIND_HOST
# Start-Process -ArgumentList does NOT auto-quote, so a username with a space
# (e.g. "AMT-X OPS") would split the script path - quote it explicitly.
$proxyScript = Join-Path $BASE_DIR "deploy\auth-proxy.js"
$proxy = Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList ('"' + $proxyScript + '"') `
    -WorkingDirectory $BASE_DIR -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $BASE_DIR "proxy.log") -RedirectStandardError (Join-Path $BASE_DIR "proxy.err.log")
Say "Started (harness pid=$($harness.Id), proxy pid=$($proxy.Id)). Logs: $BASE_DIR\*.log"

# Self-check: the login gate should answer (302 without a session). Retry up
# to ~30s - Windows cold-start of dsh can take a while.
Say "Self-check http://127.0.0.1:$PROXY_PORT/ ..."
$code = 0
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PROXY_PORT/" -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        $code = [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    if ($code -gt 0) { break }
}
if ($code -gt 0 -and $code -lt 500) {
    Write-Host "DONE. Open http://127.0.0.1:$PROXY_PORT and sign in with your FMS account (gate allows only $FMS_OWNER_USERNAME)" -ForegroundColor Green
} else {
    Write-Host "[ERROR] self-check failed (HTTP $code) - see logs: $BASE_DIR\*.log" -ForegroundColor Red
    exit 1
}
