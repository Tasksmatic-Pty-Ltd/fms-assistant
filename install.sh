#!/usr/bin/env bash
# fms-assistant 一键安装（Linux/macOS）— 员工本机形态。
#
# 初始版本（骨架）：Node 检查 → 锁版本装 dsh → 拷贝 profile/插件 → 生成 .env
# → systemd --user（或 nohup 兜底）启动 → 自检登录门。
# 完整版（多实例 / 卸载 / 升级）后续补充。生产环境完整步骤见 DEPLOY.md。
set -euo pipefail

DSH_VERSION="0.1.1-rc.2"
BASE_DIR="${FMS_ASSISTANT_HOME:-$HOME/.fms-assistant}"
HARNESS_PORT="${HARNESS_PORT:-3080}"
PROXY_PORT="${PROXY_PORT:-3082}"
HOST="${HOST:-127.0.0.1}"

say() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
die() { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

# 1. Node ≥ 22
command -v node >/dev/null 2>&1 || die "未安装 Node.js（需要 ≥22）：https://nodejs.org/"
NODE_MAJOR="$(node -p "process.versions.node.split('.')[0]")"
[ "$NODE_MAJOR" -ge 22 ] || die "Node 版本过低：$(node -v)（需要 ≥22）"
say "Node $(node -v)"

# 2. 锁版本安装 dsh
say "安装 @deepseek-ai/dsh@$DSH_VERSION ..."
npm install -g "@deepseek-ai/dsh@$DSH_VERSION"

# 3. 拷贝部署包
say "安装到 $BASE_DIR ..."
mkdir -p "$BASE_DIR"
cp -r deploy/harness "$BASE_DIR/"
mkdir -p "$BASE_DIR/harness/profiles/assistant/node_modules"
cp -r custom-plugins/* "$BASE_DIR/harness/profiles/assistant/node_modules/"
mkdir -p "$BASE_DIR/deploy" "$BASE_DIR/workspace"
cp deploy/auth-proxy.js "$BASE_DIR/deploy/"

# 4. 生成 .env（已存在则跳过）
ENV_FILE="$BASE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  say "填写配置（之后可手工编辑 $ENV_FILE）："
  read -rp "  FMS_MCP_URL       （中央 FMS 的 MCP 端点，如 https://fms.example.com/mcp）: " FMS_MCP_URL
  read -rp "  FMS_MCP_TOKEN     （员工自己的 MCP access token）: " FMS_MCP_TOKEN
  read -rp "  FMS_OWNER_USERNAME（员工 FMS 用户名，身份门绑定）: " FMS_OWNER_USERNAME
  read -rp "  FMS_ORIGIN        （员工登录 FMS 的地址，如 https://fms.example.com）: " FMS_ORIGIN
  [ -n "$FMS_MCP_URL" ] && [ -n "$FMS_MCP_TOKEN" ] && [ -n "$FMS_OWNER_USERNAME" ] && [ -n "$FMS_ORIGIN" ] \
    || die "四项必填（或手工编辑 $ENV_FILE 后重跑）"
  cat > "$ENV_FILE" <<EOF
FMS_MCP_URL=$FMS_MCP_URL
FMS_MCP_TOKEN=$FMS_MCP_TOKEN
FMS_OWNER_USERNAME=$FMS_OWNER_USERNAME
FMS_ORIGIN=$FMS_ORIGIN
FMS_WORKSPACE_DIR=$BASE_DIR/workspace
FMS_WORKSPACE_TITLE=公司工作区
FMS_TRUSTED_HOST=127.0.0.1:$PROXY_PORT
ASSISTANT_PORT=$PROXY_PORT
HOST=$HOST
TARGET=http://127.0.0.1:$HARNESS_PORT
EOF
  chmod 600 "$ENV_FILE"
  say ".env 已生成"
else
  say ".env 已存在，跳过配置"
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# 5. 启动（优先 systemd --user，否则 nohup 兜底）
start_with_systemd() {
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/fms-assistant.service" <<EOF
[Unit]
Description=fms-assistant harness (employee assistant)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DSH_HOME=$BASE_DIR/harness
Environment=DSH_PERMISSION_MODE=read-only
EnvironmentFile=$ENV_FILE
ExecStart=$(command -v dsh) --profile assistant --port $HARNESS_PORT --trusted-host 127.0.0.1:$PROXY_PORT
WorkingDirectory=$BASE_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  cat > "$HOME/.config/systemd/user/fms-assistant-proxy.service" <<EOF
[Unit]
Description=fms-assistant auth proxy (login gate)
After=network-online.target fms-assistant.service
Wants=network-online.target

[Service]
Type=simple
Environment=PORT=$PROXY_PORT
Environment=TARGET=http://127.0.0.1:$HARNESS_PORT
EnvironmentFile=$ENV_FILE
ExecStart=$(command -v node) $BASE_DIR/deploy/auth-proxy.js
WorkingDirectory=$BASE_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now fms-assistant.service fms-assistant-proxy.service
  say "systemd --user 已启动两个单元"
}
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-system-running >/dev/null 2>&1; then
  start_with_systemd
else
  say "无 systemd --user，用 nohup 后台启动（重启后需手动启动；建议装 PM2 或任务计划程序）"
  nohup env DSH_HOME="$BASE_DIR/harness" DSH_PERMISSION_MODE=read-only \
    FMS_MCP_TOKEN="$FMS_MCP_TOKEN" FMS_WORKSPACE_DIR="$FMS_WORKSPACE_DIR" \
    dsh --profile assistant --port "$HARNESS_PORT" --trusted-host "127.0.0.1:$PROXY_PORT" \
    > "$BASE_DIR/harness.log" 2>&1 &
  nohup env PORT="$PROXY_PORT" TARGET="http://127.0.0.1:$HARNESS_PORT" \
    FMS_ORIGIN="$FMS_ORIGIN" FMS_OWNER_USERNAME="$FMS_OWNER_USERNAME" HOST="$HOST" \
    node "$BASE_DIR/deploy/auth-proxy.js" > "$BASE_DIR/proxy.log" 2>&1 &
  say "已后台启动（日志：$BASE_DIR/*.log，停止：pkill -f 'dsh --profile'; pkill -f auth-proxy.js）"
fi

# 6. 自检：登录门应返回 302（未登录重定向）而不是连接失败
say "自检 http://127.0.0.1:$PROXY_PORT/ ..."
for _ in $(seq 1 10); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/" || true)"
  [ "$CODE" = "302" ] && break
  sleep 2
done
[ "$CODE" = "302" ] || die "自检失败（HTTP $CODE）——看日志：$BASE_DIR/proxy.log / harness.log"
say "安装完成 ✅ 打开 http://127.0.0.1:$PROXY_PORT 用 FMS 账号登录（身份门只允许 $FMS_OWNER_USERNAME）"
