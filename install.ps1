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

# 5. Start the services through start.ps1 (single source of truth for the
#    start/stop/self-check logic; install only adds the install steps).
& "$PSScriptRoot\start.ps1"
