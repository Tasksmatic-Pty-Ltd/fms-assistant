# fms-assistant 一键安装（Windows）— 员工本机形态。
#
# 初始版本（骨架）：Node 检查 → 锁版本装 dsh → 拷贝 profile/插件 → 生成 .env
# → 后台启动（生产建议改用 PM2：npm i -g pm2; pm2 start ... ; pm2 startup）。
# 完整版（PM2 集成 / 卸载 / 升级）后续补充。生产环境完整步骤见 DEPLOY.md。
$ErrorActionPreference = "Stop"

$DSH_VERSION = "0.1.1-rc.2"
$BASE_DIR = Join-Path $HOME ".fms-assistant"
$HARNESS_PORT = if ($env:HARNESS_PORT) { $env:HARNESS_PORT } else { "3080" }
$PROXY_PORT   = if ($env:PROXY_PORT)   { $env:PROXY_PORT }   else { "3082" }
$HOST         = if ($env:HOST)         { $env:HOST }         else { "127.0.0.1" }

function Say([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }

# 1. Node >= 22
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Write-Host "未安装 Node.js（需要 >= 22）：https://nodejs.org/" -ForegroundColor Red; exit 1 }
$nodeMajor = [int](node -p "process.versions.node.split('.')[0]")
if ($nodeMajor -lt 22) { Write-Host "Node 版本过低：$(node -v)（需要 >= 22）" -ForegroundColor Red; exit 1 }
Say "Node $(node -v)"

# 2. 锁版本安装 dsh
Say "安装 @deepseek-ai/dsh@$DSH_VERSION ..."
npm install -g "@deepseek-ai/dsh@$DSH_VERSION"

# 3. 拷贝部署包
Say "安装到 $BASE_DIR ..."
New-Item -ItemType Directory -Force -Path $BASE_DIR | Out-Null
Copy-Item -Recurse -Force deploy/harness (Join-Path $BASE_DIR "harness")
New-Item -ItemType Directory -Force -Path (Join-Path $BASE_DIR "harness\profiles\assistant\node_modules") | Out-Null
Copy-Item -Recurse -Force custom-plugins\* (Join-Path $BASE_DIR "harness\profiles\assistant\node_modules\")
New-Item -ItemType Directory -Force -Path (Join-Path $BASE_DIR "deploy"), (Join-Path $BASE_DIR "workspace") | Out-Null
Copy-Item -Force deploy\auth-proxy.js (Join-Path $BASE_DIR "deploy\auth-proxy.js")

# 4. 生成 .env（已存在则跳过）
$ENV_FILE = Join-Path $BASE_DIR ".env"
if (-not (Test-Path $ENV_FILE)) {
    Say "填写配置（之后可手工编辑 $ENV_FILE）："
    $FMS_MCP_URL       = Read-Host "  FMS_MCP_URL       (中央 FMS 的 MCP 端点，如 https://fms.example.com/mcp)"
    $FMS_MCP_TOKEN     = Read-Host "  FMS_MCP_TOKEN     (员工自己的 MCP access token)"
    $FMS_OWNER_USERNAME= Read-Host "  FMS_OWNER_USERNAME(员工 FMS 用户名，身份门绑定)"
    $FMS_ORIGIN        = Read-Host "  FMS_ORIGIN        (员工登录 FMS 的地址，如 https://fms.example.com)"
    if (-not ($FMS_MCP_URL -and $FMS_MCP_TOKEN -and $FMS_OWNER_USERNAME -and $FMS_ORIGIN)) {
        Write-Host "四项必填（或手工编辑 $ENV_FILE 后重跑）" -ForegroundColor Red; exit 1
    }
    $ws = Join-Path $BASE_DIR "workspace"
    @"
FMS_MCP_URL=$FMS_MCP_URL
FMS_MCP_TOKEN=$FMS_MCP_TOKEN
FMS_OWNER_USERNAME=$FMS_OWNER_USERNAME
FMS_ORIGIN=$FMS_ORIGIN
FMS_WORKSPACE_DIR=$ws
FMS_WORKSPACE_TITLE=公司工作区
FMS_TRUSTED_HOST=127.0.0.1:$PROXY_PORT
ASSISTANT_PORT=$PROXY_PORT
HOST=$HOST
TARGET=http://127.0.0.1:$HARNESS_PORT
"@ | Set-Content -Path $ENV_FILE -Encoding ASCII
    Say ".env 已生成"
} else { Say ".env 已存在，跳过配置" }

# 5. 启动（Start-Process 后台；生产建议 PM2）
Say "启动 harness(:$HARNESS_PORT) + 代理(:$PROXY_PORT) ..."
$harness = Start-Process -FilePath (Get-Command dsh).Source -ArgumentList @("--profile","assistant","--port",$HARNESS_PORT,"--trusted-host","127.0.0.1:$PROXY_PORT") `
    -WorkingDirectory $BASE_DIR -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $BASE_DIR "harness.log") -RedirectStandardError (Join-Path $BASE_DIR "harness.err.log")
$proxy = Start-Process -FilePath (Get-Command node).Source -ArgumentList @((Join-Path $BASE_DIR "deploy\auth-proxy.js")) `
    -WorkingDirectory $BASE_DIR -WindowStyle Hidden -PassThru `
    -Environment @{ PORT=$PROXY_PORT; TARGET="http://127.0.0.1:$HARNESS_PORT"; FMS_ORIGIN=$FMS_ORIGIN; FMS_OWNER_USERNAME=$FMS_OWNER_USERNAME; HOST=$HOST } `
    -RedirectStandardOutput (Join-Path $BASE_DIR "proxy.log") -RedirectStandardError (Join-Path $BASE_DIR "proxy.err.log")
Say "已启动 (harness pid=$($harness.Id), proxy pid=$($proxy.Id))。日志：$BASE_DIR\*.log"

# 6. 自检：登录门应返回 302（未登录重定向）
Say "自检 http://127.0.0.1:$PROXY_PORT/ ..."
Start-Sleep -Seconds 8
try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PROXY_PORT/" -MaximumRedirection 0 -ErrorAction Stop } catch { $r = $_.Exception.Response }
$code = if ($r) { [int]$r.StatusCode } else { 0 }
if ($code -eq 302) {
    Write-Host "安装完成 ✔ 打开 http://127.0.0.1:$PROXY_PORT 用 FMS 账号登录（身份门只允许 $FMS_OWNER_USERNAME）" -ForegroundColor Green
} else {
    Write-Host "自检失败（HTTP $code）——看日志：$BASE_DIR\*.log" -ForegroundColor Red
    exit 1
}
