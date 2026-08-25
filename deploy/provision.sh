#!/usr/bin/env bash
# fms-assistant Rails 侧一次性准备（在 FMS 服务器、tm-fms 代码目录里执行）。
#
# 本脚本只做 Rails 侧的事：迁移 → mcp_readonly 密码 → 验证 RLS 没弄瞎应用
# → 打开 assistant 开关。跑完后员工在 FMS 里自助 mint token，配进各自实例。
#
# 用法（在 FMS 服务器的 tm-fms checkout 目录里）：
#     curl -fsSL <本repo>/deploy/provision.sh -o /tmp/provision.sh
#     cd /path/to/tm-fms && bash /tmp/provision.sh
#
# 前置：Rails 部署环境已就绪（DB 可连、OPENROUTER_API_KEY 等已配），
# 数据库账号有执行迁移的权限。详细说明见 DEPLOY.md §2。
set -euo pipefail

say() { printf '\033[36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

[ -f config/application.rb ] || die "请在 tm-fms 代码目录里执行（找不到 config/application.rb）"

# 1/4 迁移
say "1/4 跑迁移（mcp_readonly 角色 + RLS + 审计表 + 文档表）..."
bin/rails db:migrate

# 2/4 mcp_readonly 登录密码
say "2/4 设置 mcp_readonly 角色登录密码 ..."
if [ -n "${MCP_READONLY_PASSWORD:-}" ]; then
  MCP_READONLY_PASSWORD="$MCP_READONLY_PASSWORD" bin/rails mcp:readonly_password
  say "    密码已设置。把 MCP_READONLY_DB_HOST/PORT/NAME/USER/PASSWORD 配进 Rails 部署环境（见 DEPLOY.md §2.4）"
else
  echo "    ⚠️ 未提供 MCP_READONLY_PASSWORD，跳过（生产必须设：MCP_READONLY_PASSWORD=<强密码> $0）"
fi

# 3/4 验证应用账号能绕过 RLS（RLS 弄瞎应用 = 全站白屏，最危险的坑）
say "3/4 验证应用 DB 账号能绕过 RLS ..."
COUNT="$(bin/rails runner 'puts Customer.count' 2>/dev/null || true)"
if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
  die "应用账号看不到 customers（count=$COUNT）——RLS 弄瞎了应用！按 DEPLOY.md §2.2：给应用账号加 BYPASSRLS，或给策略表各加一条 app_full policy"
fi
say "    ✓ 应用账号可读 customers（count=$COUNT），RLS 未弄瞎应用"

# 4/4 打开 assistant 开关（默认 false；配置每次调用从磁盘读，无需重启）
say "4/4 打开 assistant 开关（config/assistant.yml）..."
if grep -q '^assistant:' config/assistant.yml && grep -q 'enabled: true' config/assistant.yml; then
  say "    ✓ 已是 enabled: true"
else
  sed -i 's/enabled: false/enabled: true/' config/assistant.yml
  say "    ✓ config/assistant.yml → enabled: true（无需重启 Rails）"
fi

say "完成 ✅ 员工现在可以在 FMS → Settings → MCP access tokens 自助 mint token，配进各自实例的 .env（FMS_MCP_TOKEN + FMS_OWNER_USERNAME）"
