# fms-assistant — 员工智能助手部署包

基于 DeepSeek Harness 的**只读员工助手**客户端包：登录门代理 + harness profile（锁定 fms-employee preset）+ 自定义插件（CITO 品牌 / 工作区固定 / 文档上传按钮）。数据查询全部经 MCP 走**中央 FMS（tm-fms）**的 `POST /mcp`——权限复用 FMS 账号体系（CanCanCan）、RLS 行级隔离、`mcp_query_logs` 审计。

> 本仓库 = tm-fms 里 `assistant/` 目录的独立发布形态（源在 tm-fms，由同步机制保持一致）。Rails 侧的 MCP 端点 / RLS / 只读角色 / 文档提取都在 tm-fms 里，**员工机器不需要任何 Rails 代码**。

## 两种部署形态（同一份代码）

| 形态 | 说明 | 装法 |
|---|---|---|
| **员工本机** | 每员工一台电脑一个实例，浏览器开 `http://localhost:3082` | `./install.sh`（Linux/macOS）或 `.\install.ps1`（Windows） |
| **服务器集中** | 一台服务器 N 个实例（每员工独立端口/volume） | `docker compose -p fms-assistant-<user> --env-file .env.<user> -f deploy/docker-compose.assistant.yml up -d --build`，或 systemd 模板多开 |

## 一键安装（员工本机）

```bash
git clone <本仓库> fms-assistant
cd fms-assistant && ./install.sh
```

Windows（PowerShell）：

```powershell
git clone <本仓库> fms-assistant
cd fms-assistant; .\install.ps1
```

安装脚本会：检查 Node ≥ 22 → 锁版本安装 `@deepseek-ai/dsh@0.1.1-rc.2` → 拷贝 profile + 插件 → 交互填写 `.env`（`FMS_MCP_TOKEN` 员工自己的 token、`FMS_OWNER_USERNAME` 员工用户名、`FMS_MCP_URL`/`FMS_ORIGIN` 指向中央 FMS）→ 启动并自检登录门。

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
