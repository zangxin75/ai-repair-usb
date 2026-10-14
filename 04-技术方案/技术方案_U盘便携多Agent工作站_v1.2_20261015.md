# 技术方案：U盘便携多 Agent 工作站（v1.2）

- 创建日期：2026-10-14
- 状态：**v1.2 定稿（v1.1 复审 ACCEPT；本版新增「制作时 Agent 勾选」需求 §4.0）**
- 审计记录：v1.0 退回（2 BLOCKER + 4 MAJOR），本版逐项落实，见文末「修订记录」
- 前置：`技术方案_AI电脑维修U盘_场景三Windows在线维修新增功能_20261013.md`（V1.2 定稿）、制作器 v1.1.0（便携 claude.exe + PortableGit 已上线）

---

## 1. 背景与目标

### 1.1 定位演进

U盘 已完成三级跳：

| 阶段 | 定位 | 状态 |
|---|---|---|
| v0.1-v0.2 | 维修工具（U盘启动的 Debian Live + Claude） | 已发布 |
| 场景③ v0.2.0 | Windows 内双击维修（便携 claude.exe + PortableGit，免安装直跑） | 制作器已上线 |
| **本方案** | **随身多 Agent AI 工作站**：任意 Windows 上即插即用的维修 + 办公 + 文案 + 场景引导 + 多 agent 并用 | 设计中 |

### 1.2 商业目标（本方案的驱动力）

- **增加 token 消耗**：办公/文案/agent 日常使用是高频连续消耗，远超维修场景的低频 bursts；
- **转化路径**：免费额度（维修向）→ 用量起来 → 触达额度墙 → **购买 token 套餐**；
- 同一网关 key 统一计量、统一报表，多 agent 是消耗放大器而非新的账号体系。

### 1.3 目标 / 非目标

**目标**
1. 启动器新增「办公助手」模式（写作/文案/网页内容/场景引导，轻量人格，复用凭证与零残留策略）；
2. 集成使用量大的 agent：**Codex（OpenAI）**、**OpenClaw**、**Pi**，与 Claude Code 并列可选；
3. 所有 agent 共用 U盘 `/config/auth_token` 同一网关 key；
4. 制作器一键分发上述全部运行时，目标电脑零安装。

**非目标**
- 不改变 U盘引导维修（场景②）链路；
- 不在本方案内做套餐支付流程（仅做额度提示与引导文案，支付走 portal 既有体系）；
- 不集成需要重后端/账号绑定的 agent（如需登录厂商账号的，一律通过网关代理解决）。

---

## 2. 总体架构

### 2.1 U盘 数据分区布局（目标态）

```
U盘(exFAT)
├─ repair-on-windows.bat          统一入口（更名观察项：AI-Workstation.bat，见 §6.1）
├─ bin\
│   ├─ claude.exe                 ~236MB  Claude Code 原生版（已完成）
│   ├─ codex.exe                  ~334MB  Codex CLI Rust 单文件（自带运行时；官方 Release 实测 333.5MB，zip 164.7MB / zst 82.1MB）
│   ├─ PortableGit\               ~330MB  bash/git（已完成）
│   ├─ node\                      ~110MB  便携 Node（OpenClaw / Pi 运行时）
│   ├─ openclaw\                  ~250MB  预安装 node_modules（制作时 npm ci 打包）
│   └─ pi\                        ~120MB  同上（含 npm 缓存重定向目录，见 §3.3）
├─ config\
│   ├─ auth_token                 共享网关 key（已有）
│   ├─ claude-config\             Claude 配置/提示词（已有）
│   ├─ codex\config.toml          Codex 自定义 model_provider → 网关
│   ├─ office\CLAUDE.md           办公助手人格（新增）
│   └─ agents.json                agent 清单与版本（启动器渲染菜单用）
├─ ISO\                           系统镜像（Ventoy 启动层，既有目录，见 §4.0-[5]）
│   ├─ AI-Repair-Live-*.iso       维修系统（已有，随制作器写入）
│   └─ debian-12-netinst.iso      可选：Debian 12 安装镜像 ~650MB（勾选 [5] 才下载）
└─ tasks\ ...
```

容量预算合计 ~1.6GB（16GB 盘余量充足；8GB 盘走「精简档（仅 Claude+Codex ~0.9GB）」——见 R5）。

### 2.2 共享网关 key：协议适配层

**2026-10-14 实测 + 用户确认（§9 Q2）**：`tokeneff.com/v1/chat/completions` 与 `/v1/responses` 均已存在（未带凭证 POST 返回 401，端点在、等鉴权）。OpenAI 兼容端点确认支撑，剩余待实测项只剩「当期 codex 版本对两种 wire_api 的实际支持」（见 §3.2 实测门）。

关键前提：**网关（tokeneff / LiteLLM 栈）同时暴露两种协议端点**：

| Agent | 客户端协议 | 网关端点 | 凭证注入 |
|---|---|---|---|
| Claude Code | Anthropic Messages | `/anthropic`（已有） | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`（已实现） |
| Codex | OpenAI Responses/Chat | `/v1`（OpenAI 兼容） | 仅 `TOKENEFF_API_KEY`（base_url 写死在 config.toml，不另设 env 以免双源歧义） |
| OpenClaw | Anthropic（可配 OpenAI） | `/anthropic` | 启动器注入同 Claude 的两个 env |
| Pi | Anthropic / OpenAI 可配 | 同上 | 同上 |

- 全部读同一个 `/config/auth_token`；网关按 key 聚合计量，报表可按 `user-agent` 头细分 agent；
- 额度墙逻辑在网关侧统一实现（滑动窗口、余量提示）。**错误翻译改两层**（审计 M1）：启动器无法窥视 CLI 子进程会话中途的 HTTP 429/401，故 ①网关在 429/401 响应体注入结构化中文提示（多数 CLI 会透传 error message），②启动器仅对「会话异常退出」做兜底中文文案。

> **待确认（P-A 线上复测，不可延后）**：①`/v1/responses` 已于 2026-07-14 端到端验证（见 R2 引用文档），P-A 只需**线上复测确认**（真 token 各打 `/v1/chat/completions` 与 `/v1/responses` 一次，前置：网关可达）；②当期最新版 codex.exe 以 `wire_api="responses"` 起真实会话（新版 Codex 硬性弃用 chat，`wire_api="chat"` 不再尝试，见 R2）。复测不通则 Codex 降 P1。

### 2.3 启动器改造（repair-on-windows.ps1 → AI 工作台）

```
══════ AI 工作台（U盘）══════
 [1] 维修这台电脑      （原维修/只读会话，人格不变）
 [2] 办公助手          （写作 / 文案 / 网页内容 / 场景引导）
 [3] 选择 AI 引擎      （Claude / Codex / OpenClaw / Pi，含各引擎适用场景一句话）
 [4] 查询余额 / 套餐
```

- **模式菜单先于提权**（审计 M4）：现有启动器无条件自提权（UAC 弹窗）。办公场景在客户办公室电脑上弹 UAC 直接劝退商业目标用户。改造：启动器先出模式菜单，仅 [1] 维修模式触发提权；[2][3][4] 全程免管理员运行；
- 模式 [2] 与 [3] 正交：办公助手默认 Claude，可在 [3] 切引擎。**人格文件按引擎适配**：`config\office\CLAUDE.md` 是 Claude 专属机制，切 Codex 时改挂 `AGENTS.md`（U盘 侧同名异构文件，启动器按引擎选择），P-B 引擎齐后统一；
- 办公模式系统提示词 `config\office\CLAUDE.md`：轻量、不加维修护栏、鼓励长任务（写作/改稿/网页内容批量生成正是高消耗场景）；
- 引擎启动器统一模板：`PATH 前置 → env 注入 → 启动 → 会话回落菜单`，缺哪个二进制就隐藏哪项（制作器失败降级的自然结果）。

---

## 3. Agent 逐项集成方案

### 3.1 Claude Code（基线，已完成）

便携 exe + PortableGit + 回落在线安装链路已上线（制作器 v1.1.0）。作为其余 agent 的模式样板。

### 3.2 Codex CLI（P0，可行性最高）

- **分发**：官方 Rust 单文件 `codex-x86_64-pc-windows-msvc.exe`（**实测 333.5MB**；分发 zip 164.7MB / zst 82.1MB），自带运行时，无需 Node；
- **零残留（审计 B2 修正）**：Codex 默认读写 `~/.codex\`（配置 + 会话日志/状态），照默认会在目标机落残留并读不到 U盘 配置。启动器必须注入 `CODEX_HOME=<U盘>\config\codex`（对齐 Claude 已有的 `CLAUDE_CONFIG_DIR` 机制），并实测该版本尊重此变量；
- **Git 依赖（审计 M2 修正）**：Codex 官方 Windows 文档仍建议 Git 2.30+（shell/仓库功能依赖）。零成本复用现有资产：启动器对 Codex 同样前置 `bin\PortableGit` 的 PATH；「无 Git 裸机上 Codex 功能边界」列入 K1a 验收；
- **网关接入**：`config\codex\config.toml` 写死 model_provider：

```toml
[model_providers.tokeneff]
name = "tokeneff gateway"
base_url = "https://tokeneff.com/v1"           # 主域 /v1/ 由 nginx 代理到网关；/v1/responses 已端到端验证（见 R2 引用文档）
env_key = "TOKENEFF_API_KEY"
wire_api = "responses"                        # 新版 Codex 硬性弃用 chat（见 §2.2）

[model]
provider = "tokeneff"
model = "<网关模型名>"                         # 缺 model Codex 会报错；P-A 实测时定
```

启动器把 `auth_token` 内容注入 `TOKENEFF_API_KEY`（进程环境，不落盘）；
- **制作器**：下载 exe（官方 Release 直链 + 发布侧钉 sha256 或动态取 release API digest）→ `bin\codex.exe`；
- **风险**：Codex 版本迭代快、config.toml 字段有变动史，启动器需容忍解析失败并给出「引擎暂不可用」而非崩溃。

### 3.3 便携 Node 运行时（P0 基础设施，OpenClaw/Pi 共用）

- 官方 `node-vXX-x64.zip` 解压即用（~110MB），无安装器、无注册表写入；
- 钉版本 + sha256，制作器下载解压到 `bin\node\`；启动器 PATH 前置 `bin\node\`；
- **残留点（审计补）**：npm 缓存默认写 `%LOCALAPPDATA%\npm-cache`。启动器统一注入 `npm_config_cache=<U盘>\config\npm-cache`（预装包模式下通常不触发包管理，属保险层）；
- **exFAT 坑**：无符号链接 → npm 包的 `.bin` 链接失效。规避：启动器/脚本**不通过 npm run 启动**，直接 `node <包内 js 入口>`；node_modules 内部个别包若有 symlink 依赖需实测（见风险表）。

### 3.4 OpenClaw（P1，重量级、消耗大户）

- **形态**：npm 包 `openclaw`（单 bin，65 依赖），设计为常驻个人 agent（多渠道、守护进程、大量本地状态）；
- **集成方式**：制作时在构建机上 `npm ci --omit=dev` 得到自包含 `node_modules`，整目录拷入 `bin\openclaw\`；启动器 `node bin\openclaw\node_modules\openclaw\dist\cli.js` 直启；
- **状态目录**重定向到 U盘 `config\openclaw\`：OpenClaw 以 `OPENCLAW_STATE_DIR`（实现期以官方文档变量名为准，此处为占位名）注入；其内部若用 SQLite，exFAT 无 POSIX 文件锁语义——**默认「按需启动、退出即停」而非开机常驻**，并在 K1b 验证拔盘时机（写库中途拔 = 库损坏可接受范围，配置走定期提示备份）；
- **消耗定位**：它是四引擎中最重的 token 消耗器（自主循环），也是套餐转化的主力引擎；
- **降级**：任一环节失败（npm 解包/入口缺失）→ 启动器隐藏该项，不阻断制作。

### 3.5 Pi（P1，待定位确认）

- npm `@mariozechner/pi`（bin `pi-pods`）；与 Claude Code 同为交互式编码 agent，协议 Anthropic/OpenAI 可配；
- 集成成本与 OpenClaw 同级（Node + 入口直启），但形态轻（非常驻）；
- **零残留（审计 B2 同类补）**：确认其状态目录（如 `~/.pi`）并以 env 重定向到 U盘 `config\pi\`；
- **身份已确认（§9 Q1）**：即 `@mariozechner/pi` 编码 agent，本节适用，排入 P-B。

### 3.6 明确不集成的（记录理由，防后人误补）

- **Node.js 安装版 / Git 安装版**：便携 zip 已覆盖，安装版违背零残留原则；
- **厂商官方账号登录态类 agent**（需 OAuth 到厂商账号的）：与共享网关 key 模式冲突。

---

## 4. 制作器改动（两侧对齐）

0. **Agent 勾选（2026-10-15 新增需求，用户拍板）**：制作时让用户勾选要集成的 agent，**选哪个装哪个，不选不装**，尊重不同使用习惯：
   - Windows（`usb-v1.0.ps1`）：**Win ISO 选择（第 5 步）之后、组件下载（第 6/7 步）之前**插入勾选步骤，出编号勾选菜单（数字多选，PS 5.1 兼容，无 GUI 依赖）：
     ```
     选择要集成到 U盘 的 AI 引擎（输入编号，逗号分隔，回车=默认 [1]）：
       [1] Claude Code   默认勾选（维修场景核心，建议保留）
       [2] Codex CLI     ~334MB
       [3] OpenClaw      ~380MB（需 Node）
       [4] Pi            ~190MB（需 Node）
       [5] Linux 安装镜像 Debian 12 netinst ~650MB（用这块 U盘 装 Linux 系统）
     选择 Node 运行时：仅当勾选了 [3]/[4] 才提示是否安装（~110MB）
     ```
   - **[5] Linux 安装镜像（2026-10-15 新增需求）**：让 U盘 兼具**安装 Linux 系统**的能力：
     - 下载 Debian 12 netinst ISO（官方 CDN，sha256 钉 Debian 官方发布的 `SHA256SUMS` 值，供应链策略与 R8 对齐）到 U盘 **现有 `ISO\` 目录**（两侧制作器与 ventoy.json 别名 / VTOY_DEFAULT_IMAGE 均已指向 `ISO\`，复用之，**不另建 isos\ 目录**避免双目录）。Ventoy 递归搜全盘，`ISO\` 下新 ISO 开机即出现在启动菜单——**零引导层改造**；ventoy.json 同步加中文别名「安装 Debian 12」；
     - 选 Debian 12 作默认（与维修系统同源，netinst 最小 ~650MB）；Ubuntu LTS 作第二选项推后（~2GB，P-B 后再议）；进阶用户可手动把任何发行版 ISO 拷入 `ISO\`，完成页提示一句即可；
     - 勾选语义同引擎项：不选不下载；清单写 `config\isos.json`（镜像名/sha256/来源），完成页据此裁剪（usb-web 手动下载页过滤为展示层改造，P-C）；
     - 验收并入 K1a：勾选 [5] 制作的盘，开机 Ventoy 菜单出现「安装 Debian 12」项、进入安装器界面即算过（完整装一遍不在验收范围）。
   - Claude **默认勾选可取消**（维修 U盘 的根定位仍在，但尊重纯办公用户；取消时完成页提示「此盘无维修模式引擎」）。取消 Claude 时 `repair-on-windows.bat` 入口**仍投放**（U盘 双击入口是场景③根基），但启动器读到 agents.json「主动不装」后**不走在线安装回落链路**（该回落只服务「下载失败」），直接提示「重跑制作命令可补装」；
   - 菜单输入容错：容忍空格/重复项/非法编号，非法则重 prompt（PS 5.1 Read-Host + split 解析，无 GUI 依赖）；
   - Linux（`usb-v1.0.sh`）：同位置的 y/n 逐项问答 + `--agents claude,codex` 命令行参数（脚本可全自动化）；
   - 勾选结果写进 `config\agents.json`（含「用户主动不装」语义，区别于「下载失败未装」；渲染规则显式约定：**主动不装 → 灰色「未安装」行 + [4] 补装指引；下载失败未装 → 隐藏（沿用 §2.3）**）；
   - 下载体积分档生效：全选（含 [5]）~2.3GB；仅 Claude ~236MB。
   - **容量预检按勾选动态计算**：现有硬编码 ≥8GB 门槛（ps1 `MinDiskGB=8` / sh 同）改为「基础需求（Live ISO 1.4GB + 组件 ~0.5GB + Ventoy 盘尾保留 2GB（`/R:2048`）+ 余量 1GB ≈ 5GB）+ 勾选项体积」动态累加：全选且含 Win ISO（~6GB）约 10.4GB → 提示需 ≥16GB 盘；仅默认 Claude 约 3.3GB → 8GB 盘足够。空间不足时列出「取消部分勾选项」建议而非直接退出；
   - 组件清单裁剪对象是**制作器内存中的下载列表**（manifest.json 是发布侧共享文件，每次发布重写，不按用户勾选改写）；usb-web「手动下载组件」页按 `isos.json`/`agents.json` 勾选状态过滤展示（展示层改造，P-C；P-A 期该页照旧全列组件由用户自选）。
1. 新增第 6.6 步「多 Agent 运行时下载」：codex exe / node zip / openclaw+pi 预装包，逐项 sha256 校验、逐项可失败降级（沿用便携 claude 的 Temp→校验→mv 模式）；**下载范围 = 勾选结果**，未勾选项整段跳过（零下载、零提问）；
2. OpenClaw/Pi 的 node_modules 预装包在**构建机（构建机）上制作**为自托管 zip（同 PortableGit 模式：官方源构建、钉 sha256、自家 CDN 分发），避免客户机制作时现场 npm install 的网络不确定性；
3. `config\agents.json` 生成：记录本次实际放入的引擎与版本（含勾选语义，见第 0 条），启动器据此渲染菜单（缺则隐藏）；
4. 完成提示与 FAQ 同步更新「这是一台随身 AI 工作站」话术，并列出本次实际装了哪些引擎。

---

## 5. 计费与转化触点

1. **额度墙前引导**：网关在余量 <20% 时于响应头/错误信息带上中文提示，启动器余额页同步显示「预计可用天数」（现状：启动器低水位阈值硬编码 200 万 token，`repair-on-windows.ps1:538`，多 agent 高消耗下需网关配合重算，P-C 改造）；
2. **套餐入口**：余额页/额度墙文案统一指向 `tokeneff.com/pricing`（portal 既有页面）；
3. **报表**：按 key × agent 维度出用量，为后续「哪个引擎最拉消耗」提供数据；
4. **反噬防护**：免费额度对常驻型 agent（OpenClaw）设单日上限，防止一个失控循环烧光额度导致用户弃用。

---

## 6. 风险表

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R1 | exFAT 无符号链接，npm 生态包（.bin、部分依赖）失效 | 高 | 入口直启 node js；预装包在 NTFS 构建机上验证后打包；实测 OpenClaw/Pi 完整启动 |
| R2 | codex 两种 wire_api 均不可用（wire_api="chat" 疑似已废弃，/responses 依赖网关实现细节） | 低 | **已基本化解**：网关 /v1/responses 2026-07-14 已实现并端到端验证（LiteLLM 1.91.1 实测 200，见 token-efficiency 仓 `docs/Codex_CLI接入网关_Responses_API方案_20260714.md`）；§2.2 实测门降级为「线上复测确认」；仍不通则 Codex 降 P1 |
| R3 | agent 版本漂移（Codex config 字段、OpenClaw 破坏性更新） | 中 | agents.json 记版本；启动器容错降级；预装包钉版本，升级 = 重跑制作 |
| R4 | PortableGit 未跑 post-install 的兼容性 | 中 | T1 真机验证；补救 = Windows 上跑 post-install 后重打包 |
| R5 | 8GB 小盘容量不足（全选+Win ISO ~10.4GB） | 中 | §4.0 容量预检按勾选动态累加 + 不足时给「取消部分勾选」建议；小盘用户自然少选 |
| R6 | OpenClaw 常驻写盘 → U盘 磨损/exFAT 损坏；SQLite 在 exFAT 无 POSIX 锁语义，写库中拔盘 = 库损坏 | 中 | 默认按需启动；定期备份提示；K1b 验证拔盘行为 |
| R7 | 多 agent 并发烧 token 失控 | 中 | 网关侧每 key 并发/速率上限 + 日额度（额度保持既有设计用量，见 §9 Q4） |
| R8 | 供应链：新增 4 个下载源 | 高 | 全部官方源 + sha256 钉死或发布侧 digest；自托管重打包件同 PortableGit 模式 |
| R9 | 额度触墙体验弱于预期：启动器看不到会话中途 429/401，用户直面 CLI 英文报错 | 中 | 网关响应体注入结构化中文提示（第一层，P-C 网关侧）；启动器对会话异常退出兜底文案（第二层）。**第一层生效前（P-C 前）仅第二层可用，属已知并接受的窗口期** |

---

## 7. 分期计划

| 期 | 内容 | 前置 |
|---|---|---|
| P-A（P0） | ①§2.2 线上复测确认（/v1/responses 已有 7 月端到端证据；网关域名 = `tokeneff.com`（nginx /v1/ 代理，无 api 子域），2026-10-15 实测三端点 401 路由全通）；②办公助手模式 + 启动器「菜单先于提权」改造；③Codex 集成（若复测通过）；④制作器 Agent 勾选交互（§4.0，[1] Claude / [2] Codex / [5] Linux ISO 三项先行，[3]/[4] 留 P-B） | 本方案定稿（Q1 关闭不阻塞 P-A） |
| P-B（P1） | 便携 Node + Pi（Q1 确认后）+ OpenClaw | P-A 验收 |
| P-C（P2） | 计费报表、额度墙文案、套餐转化漏斗数据 | 网关侧配合（Q4 已于 §9 关闭） |

---

## 8. 验收（按分期拆分，真机）

**K1a（P-A 末，Claude + Codex 两引擎）**
1. 干净 Windows（无 Git/Node/Python）：两引擎从 U盘 启动并各完成一次网关对话（**可执行判据**：会话内执行「让 agent 回答固定问题并退出」，检查输出非空 + portal 报表该 key 用量 +1 次调用）；
2. 同一 key 消耗计入同一余额（portal 报表核对）；
3. 拔盘后目标电脑无残留：`%USERPROFILE%\.codex`、`.claude`、`.pi`、npm 缓存目录均不存在（**dir 判空判据**）；
4. 删 `bin\codex.exe` → 启动器隐藏 Codex 项，Claude 正常（降级演练）；
5. Codex 无 Git 裸机功能边界记录（M2：结论写入验收报告，决定是否强制前置 PortableGit）；
6. 勾选 [5] 的盘：开机 Ventoy 菜单出现「安装 Debian 12」项，选中进入安装器首屏即算过（完整安装不在验收范围）；
7. 取消勾选 Claude 的盘：`repair-on-windows.bat` 入口存在，启动器显示灰色「未安装」且不触发在线安装回落，提示重跑制作命令补装；
8. 办公模式千字级文案生成 + 额度显示正确。

**K1b（P-B 末，+ Node/OpenClaw/Pi 四引擎全量）**
1. K1a 第 1-4 条对新增三引擎重复；
2. OpenClaw 按需启动验证 + 写库中途拔盘的库损坏恢复演练（R6）；
3. Pi 状态目录零残留确认。

---

## 9. 决策记录（原开放问题，2026-10-14 用户拍板关闭）

1. **Pi = `@mariozechner/pi`**（编码 agent）——§3.5 适用，P-B 排期成立；
2. **网关支撑 OpenAI 兼容端点**——与 §2.2 实测一致（`/v1/chat/completions`、`/v1/responses` 均在）；剩余仅 §2.2 实测门的 codex 双 wire_api 实测；
3. **入口命名：新增 `AI-Workstation.bat`，保留 `repair-on-windows.bat` 作跳转**（兼容存量盘）；制作器同时投放两个文件；
4. **免费额度保持原设计用量**（不因多 agent 上调）——R7 防失控上限沿用现有额度模型，额度墙文案引导购买套餐。

## 10. 修订记录

- **v1.2（2026-10-15）**：新增需求「制作时 Agent 勾选，选哪个装哪个」（§4.0）与「U盘 可安装 Linux 系统」（§4.0-[5]）：编号勾选菜单（PS 5.1 兼容）/ Linux y+n 问答 + `--agents` 参数；agents.json 增「主动不装」语义与灰色未装行；Debian 12 netinst ISO 落既有 `ISO\` 目录走 Ventoy 零改造引导 + `isos.json` 清单 + K1a 验收条目。第一轮审计 REVISE（0 阻碍 + 4 主要）已修订：①镜像目录并入现有 `ISO\`（不另建 isos\，ventoy.json 加中文别名）；②[5] 明确归 P-A（勾选先行三项 [1]/[2]/[5]，[3]/[4] 留 P-B）；③容量预检改按勾选动态累加（R5 回升为中、给降档建议）；④勾选插入点改为「Win ISO 选择后、组件下载前」；并吸收两条：§2.2 实测门降级为线上复测（R2 降低，引 7 月 /v1/responses 端到端证据）、P-A 前置网关可达性检查。
- **v1.1（2026-10-14）**：按审计退回意见修订——B1：网关 OpenAI 端点已实测存在，wire_api 双路径改为 P-A 实测门；B2：补 `CODEX_HOME` 重定向 + Pi 状态目录 + `npm_config_cache` 重定向；M1：错误翻译改两层并新增 R9；M2：Codex 复用 `bin\PortableGit` + K1a 功能边界验收；M3：codex 体积按官方 Release 实测修正（333.5MB）并重算容量预算 ~1.6GB；M4：模式菜单先于提权改造；拆分 K1a/K1b 并补可执行判据；§9 四个开放问题经用户拍板关闭；顺带修正启动器运行时版本号 `$ScriptVersion` 0.1.0→0.2.0。复审结论 ACCEPT。
- **v1.0（2026-10-14）**：初稿。
