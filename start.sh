#!/usr/bin/env bash
# fms-assistant start (Linux/macOS) — 从已有安装启动 harness + proxy。
# 首次安装用 install.sh；本脚本只启动，不重装。
set -euo pipefail

BASE_DIR="${FMS_ASSISTANT_HOME:-$HOME/.fms-assistant}"
ENV_FILE="$BASE_DIR/.env"
HARNESS_PORT="${HARNESS_PORT:-3081}"
PROXY_PORT="${PROXY_PORT:-3082}"
HOST="${HOST:-127.0.0.1}"

say() { printf '\033[36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE 不存在——先跑 install.sh"
command -v node >/dev/null || die "node 未安装"
command -v dsh >/dev/null || die "dsh 未安装——先跑 install.sh"
# shellcheck disable=SC1090
source "$ENV_FILE"

for p in "$HARNESS_PORT" "$PROXY_PORT"; do
  if ss -tln 2>/dev/null | grep -q ":$p "; then
    die "端口 $p 已被占用——先跑 stop.sh"
  fi
done

say "启动 harness(:$HARNESS_PORT) + proxy(:$PROXY_PORT) ..."
nohup env DSH_HOME="$BASE_DIR/harness" DSH_PERMISSION_MODE=read-only \
  FMS_MCP_TOKEN="$FMS_MCP_TOKEN" FMS_WORKSPACE_DIR="$FMS_WORKSPACE_DIR" \
  dsh --profile assistant --port "$HARNESS_PORT" --trusted-host "127.0.0.1:$PROXY_PORT" \
  > "$BASE_DIR/harness.log" 2>&1 &
nohup env PORT="$PROXY_PORT" TARGET="http://127.0.0.1:$HARNESS_PORT" \
  FMS_ORIGIN="$FMS_ORIGIN" FMS_OWNER_USERNAME="$FMS_OWNER_USERNAME" HOST="$HOST" \
  node "$BASE_DIR/deploy/auth-proxy.js" > "$BASE_DIR/proxy.log" 2>&1 &
say "已启动，日志：$BASE_DIR/*.log"

# 自检：登录门应返回 302
CODE=""
for _ in $(seq 1 15); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/" || true)"
  [ "$CODE" = "302" ] && break
  sleep 2
done
if [ "$CODE" = "302" ]; then
  echo "✅ 完成。浏览器打开 http://127.0.0.1:$PROXY_PORT 用 FMS 账号登录（身份门只允许 $FMS_OWNER_USERNAME）"
else
  die "自检未过（HTTP $CODE）——看日志 $BASE_DIR/proxy.log / harness.log"
fi
