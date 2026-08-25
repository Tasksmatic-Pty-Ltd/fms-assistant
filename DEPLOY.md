# fms-assistant 安装部署说明

> 基于 DeepSeek Harness 的只读员工助手，跟随 FMS（tm-fms）一起上线。
> 本文档自包含：按顺序执行即可完成生产部署。
> 配套代码：本仓库根目录；设计文档：`docs/HARNESS_AI_ASSISTANT_DESIGN.md`。

---

## 0. 架构速览

```
员工浏览器 ── HTTPS ──▶ nginx/caddy（TLS + 同域名）
                          │  https://fms.example.com/assistant
                          ▼
                   auth-proxy（容器 :3082，登录门）
                          │ ① 转发 FMS 会话 cookie 校验（GET /assistant/session_status）
                          │ ② 401 → 同源登录页（/users/sign_in 也由代理转发）
                          │ ③ 200 → 代理到 harness
                          ▼
                   harness（dsh web，:3080，fms-employee preset：无 shell/无文件工具）
                          │  mcp-client（streamable-http，Bearer 员工 token）
                          ▼
                   Rails POST /mcp（Mcp::Server）
                          │  工具按员工 Ability 过滤 + scope 校验 + RLS
                          ▼
                   Postgres（mcp_readonly 只读角色）+ mcp_query_logs 审计
```

- **登录门**：没有 FMS 登录 = 到不了 harness；登录后凭会话 cookie 进入（单点登录）。
- **对话范围**：preset 无任何其他工具，只能调用 `mcp__fms__*`（只读）。
- **权限**：token 绑定员工 → 其完整 Ability；越权数据被 scope/RLS 拒绝。

---

## 0.5 两个关键决定：代理 vs nginx、插件怎么装

**登录门必须存在，位置二选一**：
- **保留 Node 代理（最简单，本仓库已调试好）**：nginx 只做 TLS + 转发到
  `127.0.0.1:3082`；登录校验、同源登录页、Origin/Host 一致性、WS 转发都由
  `auth-proxy.js` 负责。
- **不要 Node 代理，nginx 直连 harness :3080**：nginx 必须自己实现登录门
  （`auth_request` → Rails `/assistant/session_status`）+ 保持 Host 头
  （`proxy_set_header Host $host`，让 harness 的 Origin==Host 信任检查通过）+
  WS 升级头 + `--trusted-host <域名>`。见 §4 的 nginx 完整示例。
  两种都不能省登录门。

**两个自定义插件**（CITO 品牌 + 工作区固定）不是独立安装的：
- **Docker**：已打进镜像（`Dockerfile` → `COPY custom-plugins/ ./node_modules/`）。
  改插件 = 改 `custom-plugins/` 后重新 build，无单独安装步骤。
- **systemd 裸机**：把 `custom-plugins/{fms-assistant-custom-ui, fms-workspace-pin}`
  拷进 profile 的 node_modules：`$DSH_HOME/profiles/assistant/node_modules/`
  （loader 与 client-modules 都从 profile 目录解析插件包）。
- 换 logo：改 `fms-assistant-custom-ui/client.js` 的 `CITO_MARK`（SVG 占位）。
  换工作区名：改 `FMS_WORKSPACE_TITLE` 环境变量。

---

## 0.6 从仓库到生产机（端到端）——镜像怎么来的、怎么送过去

**先建立一个心智模型：生产机上要部署"两个东西"，不是"一个镜像"。**

| | 内容 | 怎么部署 |
|---|---|---|
| ① FMS Rails 应用 | tm-fms repo 本体（迁移、MCP 工具、`config/assistant.yml`） | **照你们现有流程**（跟 FMS 走） |
| ② fms-assistant 层 | repo 里 `assistant/` 目录（Dockerfile + harness + 代理 + 插件） | **独立的第二个部署单元**，容器或 systemd |

`assistant/` **在 FMS repo 里**（rsync/git pull 会跟着到生产机），但**不和 Rails 一起启动**——它是单独起的服务。所谓"镜像"不是现成的下载品，是**从 `assistant/` 构建出来的**（Dockerfile 在 `deploy/Dockerfile`）。

**方式 1：生产机就地构建（最简单，无需注册表/CI）**

```bash
# 开发/CI 机：把 assistant/ 拷到生产机
rsync -av tm-fms/assistant/ deploy@prod:/srv/fms-assistant/

# 生产机：
cd /srv/fms-assistant
cp deploy/.env.example .env        # 填 FMS_MCP_URL / FMS_MCP_TOKEN / FMS_ORIGIN / FMS_TRUSTED_HOST
docker compose -f deploy/docker-compose.assistant.yml up -d --build   # 就地构建 + 启动
```

**方式 2：走镜像仓库（多台生产机 / CI 时）**

```bash
# 构建机/CI：
cd tm-fms/assistant
docker build -f deploy/Dockerfile -t registry.example.com/fms-assistant:0.1.0 .
docker push registry.example.com/fms-assistant:0.1.0
# 生产机：compose 里把 build: 换成 image: registry.example.com/fms-assistant:0.1.0
docker compose pull && docker compose up -d
```

**方式 3：不用 Docker（systemd 裸机）**——见 `deploy/fms-assistant.systemd`（含完整 unit 与插件安装步骤）。

---

## 1. 前置条件

| 项 | 要求 |
|---|---|
| 服务器 | 与 FMS 生产同一台或可访问 FMS 的机器；**能出网到 LLM API**（DeepSeek 端点） |
| Node.js | ≥ 20（部署包按 22 测试） |
| Docker | 有 Docker 就用形态 A；没有用形态 B（systemd） |
| 数据库 | FMS 生产库，且**迁移需要 superuser 连接** |
| 域名 | 助手必须挂在 **FMS 同域名**下（登录 cookie 按域名生效），如 `https://fms.example.com/assistant` |

---

## 2. Rails 侧准备（一次性，每台部署做一次）

> **一条命令跑完本节的 2.1–2.5**（在 FMS 服务器 tm-fms 目录里执行本仓库的 `deploy/provision.sh`）：
> ```bash
> cd /path/to/tm-fms
> curl -fsSL <本仓库>/deploy/provision.sh -o /tmp/provision.sh && bash /tmp/provision.sh
> ```
> 下面逐条说明它做了什么，以及出问题时怎么修。

```bash
cd /path/to/tm-fms

# 2.1 迁移：mcp_readonly 角色 + RLS 策略 + mcp_query_logs 审计表
#     ⚠️ 用 superuser 连接执行（生产 DB 账号若不是 superuser，先提权执行）
bin/rails db:migrate

# 2.2 ⚠️ 关键验证：生产应用 DB 账号必须能绕过 RLS，否则应用读不到数据
#     RLS 启用后，非 owner/superuser/BYPASSRLS 的角色会看不到任何行。
#     验证（用应用同款账号）：
#       SELECT count(*) FROM customers;    # 必须是真实行数，不是 0
#     若为 0：给应用账号加 BYPASSRLS，或给 10 张策略表各加一条
#       CREATE POLICY app_full ON <table> FOR SELECT TO <app_user> USING (true);

# 2.3 只读角色登录密码（密码只进 ENV，不进仓库）
MCP_READONLY_PASSWORD=<强密码> bin/rails mcp:readonly_password

# 2.4 把只读连接参数放进 Rails 部署环境（Rails 侧打开只读连接）
#   MCP_READONLY_DB_HOST=127.0.0.1
#   MCP_READONLY_DB_PORT=5432
#   MCP_READONLY_DB_NAME=<生产库名>
#   MCP_READONLY_DB_USER=mcp_readonly
#   MCP_READONLY_DB_PASSWORD=<上一步的强密码>

# 2.5 打开助手开关（config/assistant.yml，提交进仓库的是 false）
#   assistant:
#     enabled: true
```

**员工 token（自助，无管理员代签）**：每个员工登录 FMS → Settings → **MCP access tokens** → 签发（可设过期，只给本人）。token 一旦给外部客户端，等于该员工的全部权限——按人隔离。

---

## 3. 部署助手（二选一）

### 形态 A：Docker（推荐）

```bash
# 3A.1 把 assistant/ 拷到服务器
rsync -av assistant/ /srv/fms-assistant/

# 3A.2 配置
cd /srv/fms-assistant && cp deploy/.env.example .env
# 编辑 .env：
#   FMS_MCP_URL=http://127.0.0.1:3000/mcp      # Rails 的 MCP 端点
#   FMS_MCP_TOKEN=<该员工的 mcp_xxx token>
#   FMS_ORIGIN=https://fms.example.com         # Rails 源（代理用它校验 cookie）

# 3A.3 启动（双服务：harness + auth-proxy，各自守护）
docker compose -f deploy/docker-compose.assistant.yml up -d --build

# 3A.4 检查
docker compose -f deploy/docker-compose.assistant.yml ps    # 两个都 healthy
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3082/   # 302（跳到登录）= 正常
```

### 形态 B：systemd 裸机

见 `deploy/fms-assistant.systemd`（含完整 unit 文件与注释），要点：

```bash
npm install -g @deepseek-ai/dsh@0.1.1-rc.2        # DSH 就是 npm 安装
mkdir -p /srv/fms-assistant
cp -r deploy/harness /srv/fms-assistant/harness
cp deploy/auth-proxy.js /srv/fms-deploy/
# 写 /srv/fms-assistant/.env（FMS_MCP_URL / FMS_MCP_TOKEN / FMS_ORIGIN / PORT=3082 / TARGET=http://127.0.0.1:3080）
cp deploy/fms-assistant.systemd /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now fms-assistant fms-assistant-proxy
journalctl -u fms-assistant -f
```

---

## 4. 反向代理（nginx 示例）

**必须在 FMS 同域名下**（cookie 生效），并透传 `X-Forwarded-Proto`（TLS 终结在 nginx）：

```nginx
# /etc/nginx/sites-available/fms

# 方案 A（推荐，最省心）：保留 Node 代理 —— nginx 只做 TLS + 转发
server {
  listen 443 ssl;
  server_name fms.example.com;
  # ... ssl 证书配置 ...

  location /assistant/ {
    proxy_pass http://127.0.0.1:3082/;          # Node 代理（登录门 + WS）
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;  # 必须
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }

  # 其余 FMS 路由照旧（location / → Rails :3000）
}

# 方案 B：不用 Node 代理，nginx 直连 harness :3080 —— nginx 自己实现登录门
server {
  listen 443 ssl;
  server_name fms.example.com;

  # 登录门：把浏览器的 cookie 转给 Rails 校验
  location = /_assistant_auth {
    internal;
    proxy_pass http://127.0.0.1:3000/assistant/session_status;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Cookie $http_cookie;
  }

  location /assistant/ {
    auth_request /_assistant_auth;
    error_page 401 = @assistant_login;
    proxy_pass http://127.0.0.1:3080/;          # 直连 harness
    proxy_set_header Host $host;                 # 保持 Host，让 Origin==Host 信任检查通过
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }

  location @assistant_login {
    return 302 /users/sign_in?return_to=$scheme://$host/assistant/;
  }
  # 其余 FMS 路由照旧（location / → Rails :3000）
}
```
（方案 B 的 harness 启动参数要加 `--trusted-host fms.example.com`。）

员工访问 `https://fms.example.com/assistant` → 未登录跳登录页 → 登录后进入助手。

---

## 5. 环境变量清单

| 变量 | 位置 | 说明 |
|---|---|---|
| `MCP_READONLY_DB_*` | Rails 环境 | 只读 SQL 连接的 host/port/name/user/password |
| `MCP_READONLY_PASSWORD` | 部署时一次性 | 给 mcp_readonly 角色设登录密码 |
| `FMS_MCP_URL` | 助手 .env | Rails MCP 端点（容器可达） |
| `FMS_MCP_TOKEN` | 助手 .env | 员工的 mcp_xxx token |
| `FMS_OWNER_USERNAME` | 助手 .env | 该 token 所属员工的 **FMS 用户名**——登录门比对身份用（实例=一个员工，其他 FMS 用户登录会被 403 拒绝；不配置则 fail-closed 全员拒绝） |
| `FMS_ORIGIN` | 助手 .env | Rails 源（代理校验 cookie 用） |
| `ASSISTANT_PORT` | 助手 .env | 对外端口（默认 3082） |
| `FMS_TRUSTED_HOST` | 助手 .env | 浏览器访问助手的**公共源**（如 `127.0.0.1:3082` 或 `fms.example.com`）——harness 的 /api 信任栅栏必须认它，否则所有 RPC 403、对话打不开 |
| `ASSISTANT_URL` | **Rails 环境** | FMS 顶栏那颗机器人按钮打开的地址（新窗口）。必须是绝对地址（`https://…`），不是就忽略并告警 |
| `ASSISTANT_OWNER_USERNAME` | **Rails 环境** | FMS 侧对 `FMS_OWNER_USERNAME` 的呼应：只有这个员工看得到那颗按钮。**两边必须逐字一致**（代理是精确比较），**留空则谁都看不到**——这台实例归谁，应用猜不出来，猜错就是发一个 403 给人 |

> 最后两行在 **Rails** 那边配，不在助手 .env 里。只配了助手侧的 `FMS_OWNER_USERNAME`
> 而漏了这两个，助手本身能用，但 FMS 顶栏不会出现入口——这是刻意的静默 false，
> 日志里不会有任何提示，所以两边要一起配。

---

## 5.5 文档上传（对话内「📎 上传文档」）

员工可在对话输入框上方的「📎 上传文档」上传 **PDF / XLSX / DOCX / CSV / TXT / 图片**（单文件 ≤10MB）。流程：

1. 浏览器同源 `POST /api/assistant/v1/documents` → auth-proxy 校验 FMS 会话 cookie 后转发给 Rails（无需员工自持 api_key；API 客户端仍可用 Bearer/Basic）。
2. Rails 在**上传时**提取文本入库（不保留二进制），返回 `{id, status: ready|error, char_count, error}`。
3. 客户端自动发出「请处理文档 #<id>（<文件名>）」；agent 通过 `document.read` MCP 工具按需分页读全文（每页 ≤50k 字符，`offset`/`next_offset` 续读，`total_chars` 显示总量；入库提取上限 200 万字符——覆盖 1.5MB 价卡工作簿）。

要点：

- **图片 OCR 是部署选项**：需要服务器装 `tesseract-ocr`（Debian/Ubuntu: `apt install tesseract-ocr`）。没装时图片上传成功但 status=`error`（提示未装 tesseract）。
- 扫描件 PDF（无文本层）会得到 status=`error` 并说明"可能是扫描件"——当前版本不做 PDF OCR。
- 文档归上传员工所有，`document.read` 只读本人文档；越权读 → not found。
- 依赖 auth-proxy ≥ 本提交（含 `/api/assistant/*` → Rails 路由）；旧代理会把这些请求发去 harness 导致 404。

---

## 6. 上线验证 checklist

- [ ] 无 cookie 访问助手 → 302 到登录页（同源）
- [ ] 用 FMS 账号登录 → 跳回助手，页面/资源正常加载
- [ ] **用非绑定员工/客户账号登录后访问 → 403「本实例绑定到员工 X」**（身份门有效）
- [ ] 隐身窗口无会话 → 被拦（门有效）
- [ ] 员工 token 能查到**自己权限范围**的数据；越权客户 → refused
- [ ] whops 员工看不到 `query.sql`（admin/staff 才有）
- [ ] `SELECT * FROM mcp_query_logs` 有记录（谁、何时、查了什么，含失败）
- [ ] Rails 侧 `SELECT count(*) FROM customers` 用应用账号验证 RLS 未弄瞎应用
- [ ] 两个容器 healthy；`docker compose ps` 全部 running
- [ ] 对话里点「📎 上传文档」传一个 txt/csv → 自动发出「请处理文档 #id」，agent 能复述内容
- [ ] 传一个 15MB 文件 → 客户端提示超限，不上传
- [ ] （可选）传图片 → 有 tesseract 则能读文字，无则 status=error 且 agent 说明原因

---

## 7. 运维要点

- **升级**：改 `Dockerfile` 里的 `@deepseek-ai/dsh` 版本 → 重新 build → 新容器起好验证 → 切 nginx → 停旧（滚动）。会话在 volume，不丢。
- **吊销员工**：员工在 FMS Settings 里 revoke token → 该实例立即 401。
- **审计**：`mcp_query_logs` 表；建议加"异常大查询/非工作时间访问"告警。
- **日志**：`docker compose logs -f` / `journalctl -u fms-assistant -f`。
- **备份**：`assistant-data` volume（会话）+ Rails 正常备份（含 mcp_query_logs）。

---

## 8. 常见问题排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 登录后没跳回助手 | 早期版本缺隐藏 return_to 字段 / 跨源跳转 | 用最新 `auth-proxy.js` + 登录页带隐藏字段（已修复） |
| 工作区加载报错 | 代理 WS 握手没转发 `Sec-WebSocket-Accept` | 用最新 `auth-proxy.js`（已修复），强刷 |
| 登录 422 InvalidAuthenticityToken | 反代下 Origin 与 Rails base_url 不符 | 用最新 `auth-proxy.js`（Origin 重写，已修复） |
| 资源 301 到 /en/assets | 代理把 harness 的 `/assets/*` 误发到 Rails | 用最新 `auth-proxy.js`（登录页资源改写，已修复） |
| `query.sql` 报 internal error | Rails 环境缺 `MCP_READONLY_DB_PASSWORD` | 检查 §2.4 |
| 应用页面全空 | RLS 弄瞎了应用账号 | 检查 §2.2 |
| 助手在线但调用报错 | 生产机无法出网到 LLM API | 检查网络/防火墙 |
| 对话打不开，Console 全是 `/api/*` 403 | harness /api 信任栅栏不认代理前的公共源 | `--trusted-host` 配 `FMS_TRUSTED_HOST`（见 §5） |
