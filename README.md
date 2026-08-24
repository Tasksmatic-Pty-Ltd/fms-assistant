# fms-assistant — 员工智能助手部署包

**仓库：** https://github.com/Tasksmatic-Pty-Ltd/fms-assistant.git（私有，需 GitHub 账号有只读权限）

基于 DeepSeek Harness 的**只读员工助手**客户端包：登录门代理 + harness profile（锁定 fms-employee preset）+ 自定义插件（CITO 品牌 / 工作区固定 / 文档上传按钮）。数据查询全部经 MCP 走**中央 FMS（tm-fms）**的 `POST /mcp`——权限复用 FMS 账号体系（CanCanCan）、RLS 行级隔离、`mcp_query_logs` 审计。

> 本仓库 = tm-fms 里 `assistant/` 目录的独立发布形态（源在 tm-fms，由同步机制保持一致）。Rails 侧的 MCP 端点 / RLS / 只读角色 / 文档提取都在 tm-fms 里，**员工机器不需要任何 Rails 代码**。

## 两种部署形态（同一份代码）

| 形态 | 说明 | 装法 |
|---|---|---|
| **员工本机** | 每员工一台电脑一个实例，浏览器开 `http://localhost:3082` | `./install.sh`（Linux/macOS）或 `.\install.ps1`（Windows） |
| **服务器集中** | 一台服务器 N 个实例（每员工独立端口/volume） | `docker compose -p fms-assistant-<user> --env-file .env.<user> -f deploy/docker-compose.assistant.yml up -d --build`，或 systemd 模板多开 |

## 一键安装（员工本机）

```bash
git clone https://github.com/Tasksmatic-Pty-Ltd/fms-assistant.git fms-assistant
cd fms-assistant && ./install.sh
```

Windows（PowerShell）：

```powershell
git clone https://github.com/Tasksmatic-Pty-Ltd/fms-assistant.git fms-assistant
cd fms-assistant; .\install.ps1
```

安装脚本会：检查 Node ≥ 22 → 锁版本安装 `@deepseek-ai/dsh@0.1.1-rc.2` → 拷贝 profile + 插件 → 交互填写 `.env`（`FMS_MCP_TOKEN` 员工自己的 token、`FMS_OWNER_USERNAME` 员工用户名、`FMS_MCP_URL`/`FMS_ORIGIN` 指向中央 FMS）→ 启动并自检登录门。

## 启动 / 停止 / 查看服务

安装完成后服务由两个进程组成：**harness**（:3080，DSH 本体）和 **auth-proxy**（:3082，登录门代理）。浏览器访问 **http://localhost:3082**，用 FMS 账号登录即可（身份门只允许 `FMS_OWNER_USERNAME` 对应账号）。

### Linux / macOS（systemd --user，install.sh 默认方式）

```bash
# 启动
systemctl --user start fms-assistant.service fms-assistant-proxy.service

# 停止
systemctl --user stop fms-assistant.service fms-assistant-proxy.service

# 重启
systemctl --user restart fms-assistant.service fms-assistant-proxy.service

# 状态
systemctl --user status fms-assistant.service fms-assistant-proxy.service

# 开机自启（install.sh 已 enable；手动管理时用）
systemctl --user enable --now fms-assistant.service fms-assistant-proxy.service

# 日志
journalctl --user -u fms-assistant -f          # harness 日志
journalctl --user -u fms-assistant-proxy -f    # 代理日志
```

### Linux / macOS（无 systemd 的 nohup 兜底，install.sh 自动降级）

```bash
# 启动（install.sh 已做；手动启动同样这两条）
nohup env DSH_HOME="$HOME/.fms-assistant/harness" DSH_PERMISSION_MODE=read-only \
  FMS_MCP_TOKEN="$FMS_MCP_TOKEN" FMS_WORKSPACE_DIR="$FMS_WORKSPACE_DIR" \
  dsh --profile assistant --port 3080 --trusted-host 127.0.0.1:3082 \
  > "$HOME/.fms-assistant/harness.log" 2>&1 &
nohup env PORT=3082 TARGET="http://127.0.0.1:3080" \
  FMS_ORIGIN="$FMS_ORIGIN" FMS_OWNER_USERNAME="$FMS_OWNER_USERNAME" HOST=127.0.0.1 \
  node "$HOME/.fms-assistant/deploy/auth-proxy.js" > "$HOME/.fms-assistant/proxy.log" 2>&1 &

# 停止
pkill -f 'dsh --profile assistant'; pkill -f auth-proxy.js

# 日志
tail -f ~/.fms-assistant/harness.log ~/.fms-assistant/proxy.log
```

### Windows（install.ps1 用 Start-Process 后台启动）

```powershell
# 查看进程
Get-Process node | Where-Object { $_.Path -like '*node*' }   # harness + proxy 各一个 node 进程

# 停止
Stop-Process -Name node   # 谨慎：会停掉本机所有 node 进程，建议按 PID 停

# 日志
Get-Content "$env:USERPROFILE\.fms-assistant\harness.log" -Tail 50
Get-Content "$env:USERPROFILE\.fms-assistant\proxy.log"  -Tail 50
```

生产建议在 Windows 上用 **PM2** 守护（自动重启 + 开机自启）：`npm i -g pm2` 后 `pm2 start` 两个进程，`pm2 startup` 注册开机自启。

### 服务器集中形态（Docker）

```bash
# 启动（每个员工一份 .env.<user>，独立端口/volume）
docker compose -p fms-assistant-<user> --env-file .env.<user> \
  -f deploy/docker-compose.assistant.yml up -d --build

# 查看
docker compose -p fms-assistant-<user> ps

# 日志
docker compose -p fms-assistant-<user> logs -f

# 停止
docker compose -p fms-assistant-<user> down
```

### 自检

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3082/   # 期望 302（未登录跳登录页）
```

## 限制（员工只能做 FMS 相关工作）

- **preset 锁定**：无 shell / 无文件工具 / 无子代理 / 无 web——agent 只能调 MCP 工具
- **sandbox 只读 + 工作区固定**（Linux landlock / Windows ACL）
- **身份门**：实例绑定 `FMS_OWNER_USERNAME`，其他 FMS 用户 403（fail-closed）
- **服务端不可绕过的三层**：token 按员工 Ability 过滤、RLS + `mcp_readonly` 只读角色、`mcp_query_logs` 审计——员工在本机改配置也拿不到超出自己 token 的数据

## 目录

```
deploy/
  auth-proxy.js                   登录门代理（会话校验 + 身份绑定 + Origin 检查）
  harness/profiles/assistant/     profile 硬化（mcp-fms、preset 锁定、sandbox 只读、工作区固定）
  harness/.agent-presets/         fms-employee agent preset
  fms-assistant.systemd           Linux systemd 单元
  docker-compose.assistant.yml   服务器集中形态
  Dockerfile
  .env.example
custom-plugins/                   fms-assistant-custom-ui（品牌）/ fms-workspace-pin / fms-doc-attach（文档上传按钮）
install.sh / install.ps1          一键安装（本机形态）
DEPLOY.md                         完整部署文档
```

## 维护

- **版本锁定**：`@deepseek-ai/dsh@0.1.1-rc.2` 锁在 install.sh/install.ps1/Dockerfile，升级改一处
- **与 tm-fms 同步**：本仓库由 tm-fms `assistant/` 同步而来（CI/脚本），两边不手工维护两份
- **吊销员工**：员工在 FMS Settings revoke token → 实例立即 401
