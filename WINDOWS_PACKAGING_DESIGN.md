# fms-assistant Windows 傻瓜化安装 / 自更新 · 实施方案（v0.1 草案）

> 状态：**仅设计，未改动任何仓库文件**。目标：把现有 `install.ps1 / start.ps1 / stop.ps1`
> 机制升级为一个"单包分发 + 双击即装 + 定时自更新"的 Windows 包，依赖全部离线随包，
> 员工机不再需要 Node、git、npm 联网。
>
> 范围外的：不做服务器集中形态（Docker/systemd 照旧）、不做 Electron/桌面壳、
> 不做跨平台（本方案只覆盖 Windows x64 员工本机形态）。

---

## 0. 结论（先读这段）

**可行，且比"做成 Inno Setup 安装器"更省事。** 因为现有脚本已经把安装动作拆得很干净，
我们只做三件事：

1. **把要联网/要 Node 的步骤全部前移到打包机**：员工机拿到的包 = 便携 Node + 装好的
   dsh + 装好的 profile/插件 + 三个文件解析依赖，全部离线。
2. **把现有脚本改成"只认包内相对路径"**（不再要求 PATH 上有 node/dsh）。
3. **新增一个 `update.ps1`**：定时从 GitHub Releases（私有仓库）拉新包 → 停服务 →
   换文件 → 自检 → （失败回滚）。

关键设计决策：**"新装"和"升级"复用同一套换文件逻辑**——因此存量机器（已用旧
`install.ps1` 装过）的升级 = 第一次自动更新，不需要单独的迁移脚本。

---

## 1. 分发产物（一个文件，两种用途）

- **产物**：`fms-assistant-bundle-<version>.zip`（下称 bundle）。
- **同一份 bundle 既是全新安装包，也是每次更新的下载体** → 更新器逻辑最简单：
  下载 zip → 校验 → 替换程序文件 → 重启，无增量/差分包。
- 体积估计：便携 Node ~30MB（zip 后）+ dsh 及依赖 ~100–150MB（dsh 带原生模块如
  koffi/node-pty）+ profile/插件 + **dsh-univer-office**（最大头：Linux 干净安装实测
  profile node_modules ≈ **339MB**，含 puppeteer-core/libsql/@univerjs-pro 等）
  ⇒ zip 后 **150–350MB 量级**（打包后实测为准）。内网/公司带宽下可接受；一次安装，
  之后只在小版本间整包替换。
- 员工拿到方式（二选一，见 §10 待定项）：
  - 私有 GitHub Releases 下载页（员工有仓库只读权限即可）；
  - IT 拷一份到内网共享盘（推荐：不需要员工有 GitHub 账号）。

> 可选包装（不在本草案主路径）：bundle 外面再套 7-Zip SFX 自解压 exe（双击 →
> 解压 → 自动跑 setup），体验更像"安装器"。zip + 双击 `setup.cmd` 已足够傻瓜，
> 建议先 zip 后 SFX，别一开始上 Inno Setup。

---

## 2. 目标目录布局（改动最小化）

员工本机安装根目录沿用现状 `%USERPROFILE%\.fms-assistant`（旧版已装过时 `.env`
路径不变，天然兼容）：

```
%USERPROFILE%\.fms-assistant\
├── .env                    ← 永不动（员工配置/机密；旧版兼容）
├── manifest.json           ← 新增：当前安装版本/构建信息（更新器比较用）
├── runtime\node\…          ← 便携 Node 22.x（zip 内原样解压）
├── global\node_modules\@deepseek-ai\dsh\…   ← dsh 及其依赖（打包机装好）
├── harness\…               ← profile + 插件 + profile 依赖（dsh-univer-office，同现状路径）
├── deploy\auth-proxy.js    ← 同现状路径
├── bin\dsh.cmd             ← 构建时生成：指向 runtime\node + global\dsh 的本地启动器
├── workspace\              ← 永不动（dsh-files 上传文件落点）
├── previous\<version>\     ← 更新器回滚快照（只放一份）
└── *.log / *.err.log       ← 日志（现有 harness.log/proxy.log 之外加 update.log）
```

**"换文件范围"（随版本替换）= {runtime, global, harness, deploy, bin, manifest.json}**
**"永不动" = {.env, workspace, *.log, previous}**。这条界线全文档统一，更新器唯一
不能越过的红线。

bundle 内部结构就是上表去掉 `.env/workspace/logs/previous` 后的镜像，外加一份
`manifest.json`。

---

## 3. manifest 与版本模型

单点版本源：仓库新增 `packaging/versions.json`（唯一要人工改的版本文件）：

```json
{
  "app":      "0.2.0",              // 本包的发布版本（tag 用 win-v0.2.0）
  "dsh":      "0.1.1-rc.2",         // 锁定的 dsh 版本
  "dshFiles": "0.4.1",              // 锁定的 vendored dsh-files
  "node":     "22.14.0"             // 便携 Node 精确版本（≥22.18 即可）
}
```

构建时写入 bundle 和安装后的 `manifest.json`（本地这份还会多一个 `installedAt`）。
**升级 dsh/dsh-files/Node 都只改这一个文件** → CI 出整包，杜绝单包升级破坏锁链
（README 已强调 dsh 0.1.1-rc.2 ↔ dsh-files 0.4.1 配套锁定）。

### 3.1 包内组件清单（已核实，按来源分类）

| 组件 | 版本 | 来源 | 进 Windows bundle |
|---|---|---|---|
| `@deepseek-ai/dsh`（框架本体 + 依赖树） | 0.1.1-rc.2 | npm，框架自身 | ✅ `global\` |
| `fms-assistant-custom-ui`（CITO 品牌 UI） | 0.1.0 | **仓库自研**（private） | ✅ `harness\…\node_modules` |
| `fms-workspace-pin`（固定工作区） | 0.1.0 | **仓库自研**（private） | ✅ 同上 |
| `dsh-files`（附件上传 + read_document） | 0.4.1 | **第三方 vendored**（taxueseek/dsh-files，MIT，commit 6b761ba） | ✅ 同上 |
| `mammoth` / `pdfjs-dist` / `read-excel-file`（dsh-files 解析依赖，纯 JS） | 1.12.2 / 4.10.38 / 5.8.8 | 第三方 npm | ✅ 同上 |
| `dsh-univer-office`（Sheet/Doc/Slide 办公 + 导出） | 0.2.10 | 第三方，锁在 pnpm-lock.yaml | ✅ `harness\profiles\assistant`（pnpm 冻结安装） |
| 宿主自带 `dsh-mcp-client` / `dsh-base` / `dsh-web-app` 等 | 随 dsh | dsh 依赖树，非另装 | ✅ 随 `global\` |
| `ui-brand-official`（官方品牌插件） | 随 dsh | dsh 依赖树 | 显式 **disabled** |

---

## 4. 构建流水线（谁产出 bundle）

**必须在一台 Windows x64 机器上构建**（dsh 的原生模块按平台预装，员工机不编译）。
用 GitHub Actions `windows-latest` runner（私有 repo 的 runner 即可）。

1. 读 `packaging/versions.json`；
2. 下载官方便携 Node zip
   `https://nodejs.org/dist/v<node>/node-v<node>-win-x64.zip`，比对官方 SHA256；
3. 用**与员工机相同的命令**预装 dsh（含 install.ps1 同款 allow-scripts 列表，避免
   新版 npm 默认禁 install 脚本）：
   ```powershell
   npm install --prefix .\stage\global "@deepseek-ai/dsh@<dsh>" `
     "--allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs"
   ```
   （失败则像 install.ps1 一样回退一次无 flag 安装。）
4. 组 profile（**顺序照 install.sh §3b/§3**：pnpm/npm 都会裁剪多余包，谁先跑都会删掉
   后拷的插件——先 pnpm → 再 npm 解析依赖 → 最后拷插件）：
   a. 拷 `deploy\harness` → `stage\app\harness`；
   b. **profile 依赖**：打包机先装 `pnpm@11.24.0`，再在
      `harness\profiles\assistant` 跑 `pnpm install --frozen-lockfile` —— 按锁文件装
      **`dsh-univer-office@0.2.10`**（唯一直接依赖，48 包依赖树）。本步已随 HEAD
      （commit 24084a0，merge 2246a21）统一补进 `install.ps1`/`install.sh`/Dockerfile；
      本节在 Linux 干净副本实测 office + 解析依赖 + 插件可共存于同一 node_modules
      （nodeLinker: hoisted，见 pnpm-workspace.yaml）；
   c. 在 `harness\profiles\assistant\node_modules` 里
      `npm install --omit=dev --no-save --no-package-lock mammoth@1.12.2
      pdfjs-dist@4.10.38 read-excel-file@5.8.8`（dsh-files 运行时解析依赖）；
   d. 拷 `custom-plugins\*` 进同一 node_modules；
5. 拷 `deploy\auth-proxy.js` → `stage\app\deploy\`；写 `manifest.json`；
6. **生成 `bin\dsh.cmd`**：npm 生成的全局 shim 会把打包机的 node 绝对路径写死，
   必须自己生成相对路径启动器，例如：
   ```
   @node "%~dp0..\runtime\node\node.exe" "%~dp0..\global\node_modules\@deepseek-ai\dsh\<cli入口>" %*
   ```
   （`<cli入口>` 在构建时读该包 package.json 的 `bin` 字段解析，不写死。）
7. 冒烟：用包内 node 跑 `dsh --version`、`node -p "typeof require('node:module').stripTypeScriptTypes"`；
8. 打 zip → 用 `gh release create win-v<ver>` 上传 asset + `<ver>.sha256`（token 用
   repo secret，见 §5）；建议先出 draft，人工点 publish。

---

## 5. 更新源与私有仓库认证

- API：`GET https://api.github.com/repos/Tasksmatic-Pty-Ltd/fms-assistant/releases/latest`
- **私有仓库必须带 token**，否则 404。token 放 `.env` 新增项
  `GITHUB_UPDATE_TOKEN=`，来源二选一：
  - **内嵌部署 token**：构建时由 CI 用一个 fine-grained PAT（**只读 Contents，仅限本
    repo**，不能用宽 scope 的 classic token）注入 bundle 里的
    `bundle.defaults`，首次安装写进 `.env`。泄露面 = 只能读这一个仓库的发布资产，
    员工本来就应有仓库读权限，风险可接受；IT 可随时轮换（轮换 = 发新版或改 .env）。
  - 员工用自己的 GitHub token（`gh auth token` 或 PAT）：更干净但不够傻瓜，作为
    备选说明即可。
- **镜像逃生口**：`.env` 支持 `GITHUB_UPDATE_URL=` 覆盖默认 API 地址。哪天不想走
  私有 GH（或员工没 GH 账号），IT 把 release asset 同步到内网一个静态 URL 并改这一
  项即可，更新器代码不变。
- 更新器只读 `.env` 里这两个可选键；读不到就跳过检查（离线也能跑，只是不更新）。

---

## 6. 员工体验（全新安装）

员工拿到 zip（或 SFX exe）后：

1. 解压到任意目录，双击 **`setup.cmd`**（沿用 cmd→PowerShell Bypass 包装模式，
   绕过执行策略；新增脚本保持 **ASCII-only**，兼容 PS 5.1）；
2. setup 检测 `%USERPROFILE%\.fms-assistant\.env`：
   - **不存在（全新）** → 弹配置向导，预填 bundle 内置的公司默认值
     （`FMS_MCP_URL`/`FMS_ORIGIN` 可在 bundle.defaults 注入，非机密），员工只需填
     两个必填项：**`FMS_MCP_TOKEN`**（自己在 FMS Settings 签发的 token）和
     **`FMS_OWNER_USERNAME`**（FMS 用户名，不是邮箱——沿用现有提示，防止填错）；
     校验非空、`/mcp` 结尾补全、用户名匹配后才写入 `.env`（UTF-8 无 BOM，同现状）；
   - **已存在（旧版升级 / 重装）** → **跳过向导**，直接走"换文件"路径（=第一次
     自更新，见 §7），`.env`、`workspace\` 原样保留；
3. 复制 bundle 内容到 `%USERPROFILE%\.fms-assistant`（换文件路径）；
4. 写 `manifest.json`；
5. 注册自启与定时更新（见 §8），**均有开关可关**；
6. 调 `start.ps1` 启动 + 302 自检（沿用现有逻辑），成功则
   `start http://localhost:3082` 打开浏览器；失败红字提示看日志。

> 员工机全程不需要 Node / git / npm。install 脚本里"Node 检查失败就 exit"、
> "npm install -g dsh"、"npm install 三个解析依赖"这几段**全部删除**——它们已经
> 在打包机做完。

---

## 7. 自更新器（核心新组件 `update.ps1`）

状态机（单实例，用文件锁或 `Start-Process -PassThru` 检查避免并发）：

```
check  读 .env 的 GITHUB_UPDATE_URL/TOKEN → 请求 latest release
        → 与本地 manifest.json 比版本号
        → 没有新版 / 离线 / 失败 → 退出 0（静默，不打扰）
stop   有新版 → 调 stop.ps1（按 3081/3082 端口杀监听进程，只杀我们的）
swap   下载 asset zip 到 %TEMP% → 比对 <ver>.sha256
       → 现有 {runtime,global,harness,deploy,bin} 整目录改名 → previous\<旧ver>
       → 解压新包到原路径（.env / workspace / logs 绝不进 swap）
verify 调 start.ps1 → 复用其 302 自检（新起服务是否答 302）
ok     删 previous\<旧ver>，manifest 写新版本，记 update.log
fail   停服务 → 删新目录 → previous\<旧ver> 改回原位 → start.ps1 → 红字记日志
```

触发方式（双保险）：

- **每次 `start.cmd` 启动前**：静默 check，发现新版提示"发现新版本正在更新…"
  然后自动走完 swap（员工总是用最新版）；
- **每日计划任务**（用户级，无需管理员）：
  `schtasks /create /tn "FMSAssistantUpdate" /tr "powershell -NoProfile -ExecutionPolicy
  Bypass -File <dir>\update.ps1" /sc daily /st 09:00 /f`
  该任务只做"检查 + 若服务在跑则更新后重启"，用于覆盖员工当天没手动 start 的情况。

回滚策略：**只保留一份 previous**；自检是"健康门"（沿用现有 302 检查 = 登录门答
302 即服务活着）。版本号比较用语义化版本（`win-v<major.minor.patch>`），不做
downgrade。

---

## 8. 开机自启（新增，默认开）

现状是每天手动 `start.cmd`；"配置及可用"建议加上：

- `schtasks /create /tn "FMSAssistant" /tr "<dir>\start.cmd" /sc onlogon /f`
  （用户级即可）；`stop.cmd` / 更新器在启动服务前先查端口占用避免双开
  （start.ps1 已有端口占用检查）。
- 提供 `setup.cmd /disable-autostart` 之类开关（细节实现时定，默认开）。

---

## 9. 对现有脚本的改动清单（逐条，实施时按此改）

| 文件 | 改动 |
|---|---|
| `install.ps1` | 删 Node 检查 / `npm install -g dsh` / profile 内三依赖安装（§4 已前移）；复制源从"仓库目录"改为"bundle 目录"；加：检测 `.env` 存在→跳向导、写 `manifest.json`、注册计划任务与自启、调 start.ps1 |
| `start.ps1` | `Get-Command dsh` 检查改为直接用包内路径：`$env:DSH_HOME=<base>\harness` 不变，dsh 调用改 `& <base>\runtime\node\node.exe <base>\global\node_modules\@deepseek-ai\dsh\<cli入口> …`；proxy 的 node 同样改包内 node；其余（.env 读取、端口检查、302 自检）不动 |
| `stop.ps1` | 不变（按端口杀监听进程，天然只杀我们的实例） |
| `install.cmd / start.cmd / stop.cmd` | 不变（wrapper 模式继续用） |
| **新增** `setup.cmd/.ps1` | 见 §6：向导/迁移/注册/启动的入口 |
| **新增** `update.ps1` + `update.cmd` | 见 §7 |
| **新增** `packaging/versions.json` | 版本单点来源（§3） |
| **新增** `.github/workflows/build-bundle.yml` | §4 的打包发布流水线 |
| `README.md / DEPLOY.md` | 补"Windows bundle 安装/更新"小节 |

全部新增/修改的 .ps1 继续 **ASCII-only**（沿用 install.ps1 头注释的原因）。

---

## 10. 安全与边界（设计必须承认的点）

- **私有 token 内嵌**：泄露面=只读本 repo 的 release 资产。用 fine-grained PAT
  （Contents:Read，单 repo），禁用宽 scope；文档写明轮换方式（改 .env 或发新版）。
- **SmartScreen / Defender**：未签名的 zip 内 `.cmd/.ps1`、自解压 exe 会被提示。
  内部分发可接受"更多信息→仍要运行"；要彻底顺滑需代码签名证书（预算+审批，可后置，
  放里程碑 M3 可选）。
- **每机单实例**：端口 3081/3082 固定，与现状一致；两员工共用一台电脑不支持（现状
  如此，文档注明）。
- **`stop.ps1` 按端口杀**：若员工本机有别的程序恰好监听 3081/3082 会被误杀——
  沿用现状行为并在安装向导里检测端口占用提前警告。
- **dsh-files 上传文件**：`workspace\` 不在 swap 范围，7 天 TTL 逻辑不变，文件不随
  更新丢失。
- **LLM/FMS 出口**：运行时仍需出网到 DeepSeek API 与公司 FMS（安装与更新不依赖）。

---

## 11. 里程碑与工作量（量级估计，人日以熟悉该仓库的人计）

| 里程碑 | 内容 | 量级 |
|---|---|---|
| **M1 离线 bundle + 新安装体验** | 布局/清单落地；install/start 去 PATH 化；向导与迁移；本地手打 zip 可装可跑 | 2–3 人日 |
| **M2 自更新** | update.ps1 + 计划任务 + 回滚 + update.log；存量机升级走同一路径验证 | 2–3 人日 |
| **M3 发布流水线 + 收尾** | versions.json + Actions 打包出 Release；README；签名（可选） | 1–2 人日 + 证书采购 |

**交付 M1 就比现状强**（员工不用装 Node、断网可装）；M2 才满足"已安装则定期自动
更新"。

---

## 12. 待你拍板的决策清单

1. **分发渠道**：员工直接从私有 GitHub Releases 下载，还是 IT 放内网共享盘？
   （影响：员工要不要 GitHub 账号；影响 §5 默认认证方式。）
2. **内嵌只读 token 是否接受**：接受 → CI 配 fine-grained PAT；不接受 →
   更新器依赖员工自己的 GitHub 凭证（傻瓜程度下降）。
3. **产物形式**：先 zip + `setup.cmd`（推荐，最快可用），还是一步到位套
   7-Zip SFX 自解压 exe？
4. **开机自启默认开还是默认关**（员工是否希望登录 Windows 就自动跑助手）。
5. **代码签名**：现在买证书（顺滑但花钱+审批）还是先用"更多信息→仍要运行"
   （零成本，内部试点足够）。
6. **bundle.defaults 注入公司值**（FMS_MCP_URL / FMS_ORIGIN）需确认这俩是公司通用
   固定值，能写进包；不能则退回安装向导手填。
7. **`dsh-univer-office` 是否进 Windows 包 —— 已定：补装**。当前 HEAD（commit
   24084a0，merge 2246a21）已给 `install.ps1`/`install.sh`/Dockerfile 统一加上
   `pnpm install --frozen-lockfile` 的 profile 依赖步骤（Windows 与 Linux/Docker
   行为现已一致；本次还补了 install.ps1 里 pnpm 步骤缺失的退出码检查）。
   Windows bundle 侧沿用 §4b 同一序列。**剩余动作**：在一台真实 Windows x64 上跑
   `install.cmd` 验证（office 的 `univer_*` 工具对 fms-employee agent 可见、
   harness 启动、302 自检通过）。
