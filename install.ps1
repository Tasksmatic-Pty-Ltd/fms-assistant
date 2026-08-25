# fms-assistant one-click installer (Windows / PowerShell 5.1+).
#
# NOTE: this file is ASCII-only ON PURPOSE. Windows PowerShell 5.1 reads a
# BOM-less .ps1 as the system ANSI codepage, so non-ASCII text breaks parsing
# on non-UTF-8 locales. UI text is English here; README.md stays UTF-8.
#
# Initial skeleton: Node check -> pinned dsh install -> copy profile/plugins
# -> interactive .env -> background start (Start-Process). For production use
# PM2 instead (npm i -g pm2; pm2 start; pm2 startup). Full steps: DEPLOY.md.
$ErrorActionPreference = "Stop"

$DSH_VERSION = "0.1.1-rc.2"
$BASE_DIR = Join-Path $HOME ".fms-assistant"
$HARNESS_PORT = if ($env:HARNESS_PORT) { $env:HARNESS_PORT } else { "3081" }
$PROXY_PORT   = if ($env:PROXY_PORT)   { $env:PROXY_PORT }   else { "3082" }
$BIND_HOST    = if ($env:HOST)         { $env:HOST }         else { "127.0.0.1" }

function Say([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }

# 1. Node: must be >= 22.18 - dsh's plugin loader imports
#    node:module.stripTypeScriptTypes, which only exists from 22.18.0.
#    Major 23.0.0 (Oct 2024) is TOO OLD despite being major 23, so probe the
#    export instead of checking the major/minor.
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host "[ERROR] Node.js is required (>= 22.18): https://nodejs.org/" -ForegroundColor Red
    exit 1
}
$hasTsStrip = (node -p "typeof require('node:module').stripTypeScriptTypes" 2>$null).Trim()
if ($hasTsStrip -ne "function") {
    Write-Host "[ERROR] Node $(node -v) is too old for dsh - need >= 22.18. Install the latest Node 22 LTS or 24: https://nodejs.org/ (or: winget install OpenJS.NodeJS.LTS)" -ForegroundColor Red
    exit 1
}
Say "Node $(node -v)"

# 2. Install the pinned dsh version. npm 11.6+/12 blocks install scripts by
#    default (allow-scripts); dsh needs the native-module prep scripts
#    (dsh-subprocess-local spawn helper, node-pty, koffi) or the harness
#    cannot start. Fall back to a plain install on older npm that lacks the
#    flag.
Say "Installing @deepseek-ai/dsh@$DSH_VERSION ..."
$allowScripts = "@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs"
npm install -g "@deepseek-ai/dsh@$DSH_VERSION" "--allow-scripts=$allowScripts"
if ($LASTEXITCODE -ne 0) { npm install -g "@deepseek-ai/dsh@$DSH_VERSION" }
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] npm install failed" -ForegroundColor Red; exit 1 }

# 3. Copy the deploy package
Say "Installing to $BASE_DIR ..."
New-Item -ItemType Directory -Force -Path $BASE_DIR | Out-Null
Copy-Item -Recurse -Force deploy\harness (Join-Path $BASE_DIR "harness")
New-Item -ItemType Directory -Force -Path (Join-Path $BASE_DIR "harness\profiles\assistant\node_modules") | Out-Null
Copy-Item -Recurse -Force custom-plugins\* (Join-Path $BASE_DIR "harness\profiles\assistant\node_modules\")
New-Item -ItemType Directory -Force -Path (Join-Path $BASE_DIR "deploy"), (Join-Path $BASE_DIR "workspace") | Out-Null
Copy-Item -Force deploy\auth-proxy.js (Join-Path $BASE_DIR "deploy\auth-proxy.js")

# 4. Generate .env (skip if it already exists)
$ENV_FILE = Join-Path $BASE_DIR ".env"
if (-not (Test-Path $ENV_FILE)) {
    Say "Configuration (you can edit $ENV_FILE later and restart):"
    $FMS_MCP_URL        = Read-Host "  FMS_MCP_URL         (central FMS MCP endpoint, e.g. https://fms.example.com/mcp)"
    $FMS_MCP_TOKEN      = Read-Host "  FMS_MCP_TOKEN       (employee's own MCP token, mcp_xxx)"
    $FMS_OWNER_USERNAME = Read-Host "  FMS_OWNER_USERNAME  (employee's FMS username - NOT the email)"
    $FMS_ORIGIN         = Read-Host "  FMS_ORIGIN          (FMS login origin, e.g. https://fms.example.com)"
    $FMS_MCP_URL        = $FMS_MCP_URL.Trim().TrimEnd('/')
    $FMS_MCP_TOKEN      = $FMS_MCP_TOKEN.Trim()
    $FMS_OWNER_USERNAME = $FMS_OWNER_USERNAME.Trim()
    $FMS_ORIGIN         = $FMS_ORIGIN.Trim().TrimEnd('/')
    # The FMS MCP endpoint is the fixed Rails route POST /mcp - append it when
    # the user typed just the origin, so the instance connects on first try.
    if (-not $FMS_MCP_URL.EndsWith("/mcp")) { $FMS_MCP_URL = "$FMS_MCP_URL/mcp" }
    if (-not ($FMS_MCP_URL -and $FMS_MCP_TOKEN -and $FMS_OWNER_USERNAME -and $FMS_ORIGIN)) {
        Write-Host "[ERROR] All four are required (or edit $ENV_FILE and re-run)" -ForegroundColor Red
        exit 1
    }
    $ws = Join-Path $BASE_DIR "workspace"
    $envContent = @"
FMS_MCP_URL=$FMS_MCP_URL
FMS_MCP_TOKEN=$FMS_MCP_TOKEN
FMS_OWNER_USERNAME=$FMS_OWNER_USERNAME
FMS_ORIGIN=$FMS_ORIGIN
FMS_WORKSPACE_DIR=$ws
FMS_WORKSPACE_TITLE=Company Workspace
FMS_TRUSTED_HOST=127.0.0.1:$PROXY_PORT
ASSISTANT_PORT=$PROXY_PORT
HOST=$BIND_HOST
TARGET=http://127.0.0.1:$HARNESS_PORT
"@
    [System.IO.File]::WriteAllText($ENV_FILE, $envContent)   # UTF-8, no BOM
    Say ".env generated"
} else {
    Say ".env exists, skipping configuration"
}

# Read .env into a map (PS 5.1 safe).
$envMap = @{}
Get-Content $ENV_FILE | ForEach-Object {
    if ($_ -match '^([A-Z_]+)=(.*)$') { $envMap[$matches[1]] = $matches[2] }
}

# 4.5. Ports free? A leftover harness/proxy from an earlier run would make the
#     new one die with EADDRINUSE and the self-check fail with HTTP 0.
foreach ($p in @($HARNESS_PORT, $PROXY_PORT)) {
    $inUse = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        Write-Host "[ERROR] port $p is already in use by PID $($inUse.OwningProcess) - stop it first (netstat -ano | findstr :$p) and re-run" -ForegroundColor Red
        exit 1
    }
}

# 5. Start harness (:HARNESS_PORT) + proxy (:PROXY_PORT) in the background.
#    Child processes inherit $env:, so set them on the session first.
Say "Starting harness (port $HARNESS_PORT) + proxy (port $PROXY_PORT) ..."
$env:DSH_HOME = Join-Path $BASE_DIR "harness"
$env:DSH_PERMISSION_MODE = "read-only"
$env:FMS_MCP_TOKEN = $envMap["FMS_MCP_TOKEN"]
$env:FMS_WORKSPACE_DIR = $envMap["FMS_WORKSPACE_DIR"]
$env:FMS_WORKSPACE_TITLE = $envMap["FMS_WORKSPACE_TITLE"]
# On Windows, `npm install -g` installs dsh as a .cmd shim, and Start-Process
# cannot execute a .cmd directly ("%1 is not a valid Win32 application") - run
# it through cmd.exe /c instead.
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
$proxy = Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList @((Join-Path $BASE_DIR "deploy\auth-proxy.js")) `
    -WorkingDirectory $BASE_DIR -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $BASE_DIR "proxy.log") -RedirectStandardError (Join-Path $BASE_DIR "proxy.err.log")
Say "Started (harness pid=$($harness.Id), proxy pid=$($proxy.Id)). Logs: $BASE_DIR\*.log"

# 6. Self-check: the login gate should answer (302 to the login page without a
#    session). Windows cold-start of dsh can take >8s, so retry up to ~30s
#    instead of failing on the first probe.
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
    if ($code -gt 0) { break }   # any answer means the gate is up
}
if ($code -gt 0 -and $code -lt 500) {
    Write-Host "DONE. Open http://127.0.0.1:$PROXY_PORT and sign in with your FMS account (gate allows only $FMS_OWNER_USERNAME)" -ForegroundColor Green
} else {
    Write-Host "[ERROR] self-check failed (HTTP $code) - see logs: $BASE_DIR\*.log" -ForegroundColor Red
    exit 1
}
