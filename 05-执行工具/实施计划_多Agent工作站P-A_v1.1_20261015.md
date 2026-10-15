# 实施计划：U盘便携多 Agent 工作站 P-A（Claude/Codex 勾选 + 办公模式 + Linux ISO）

- 创建日期：2026-10-15
- 版本：v1.1（定稿，审计 ACCEPT）
- 状态：A2/A4/A5 已实施并通过 smoke 29/29（2026-10-15）；A1 真 token 复测与 A3 上线待用户提供测试 key
- 作者：kt + Claude Code
- 上游设计：`04-技术方案/技术方案_U盘便携多Agent工作站_v1.2_20261015.md`（两轮审计后 ACCEPT，残留清零）

## 0. 范围与前置

**做（P-A 四项）**：
- A1 网关线上复测（域名 = `tokeneff.com/v1`，nginx /v1/ 代理；2026-10-15 已实测三端点 401 路由全通——之前的「不可达」是误用 api 子域）
- A2 启动器「菜单先于提权」改造 + 办公助手模式（repair-on-windows.ps1 0.2.0 → 0.3.0）
- A3 Codex CLI 集成（bin\codex.exe + config\codex\config.toml + 启动器入口）
- A4 制作器 Agent 勾选交互（usb-v1.0.ps1/sh：编号菜单 + y/n 问答 + --agents；agents.json/isos.json；容量动态预检；ventoy.json 别名；`AI-Workstation.bat` 双入口投放）

**不做（留 P-B/P-C）**：OpenClaw/Pi/Node 运行时（[3]/[4] 菜单项显示但标注「暂未提供」还是直接不显示——**不显示**，菜单只列可装项，避免空承诺）；网关侧额度墙/报表改造；热更新通道。

**前置条件**：
- 设计 v1.2 ACCEPT ✅
- 网关 `tokeneff.com/v1` 路由可达 ✅（401 = 路由通待鉴权；真 token 复测在 A1 执行）
- usb-web maker 通道现状：`build/maker/` → portal/usb-web/maker/ 同步已建立 ✅

**涉及文件**：
| 文件 | 动作 |
|---|---|
| `build/maker/usb-v1.0.ps1` | 改：勾选步骤、容量动态预检、agents.json/isos.json 生成、codex/Debian 下载步骤、ventoy.json 别名、AI-Workstation.bat 投放 |
| `build/maker/usb-v1.0.sh` | 改：同上 Linux 侧（y/n + --agents） |
| `build/maker/repair-on-windows.ps1` | 改：菜单先于提权、办公模式、Codex 入口、灰色未装行 |
| `build/maker/repair-on-windows.bat` | 改：**删除自带 UAC 提权块**（现 bat:15-20 的 net session + -Verb RunAs 重入），改为仅设编码/执行策略后直接调 ps1——提权改由 ps1 模式菜单选 [1] 时按需触发 |
| `build/maker/AI-Workstation.bat`（新） | **内容与改造后的 repair-on-windows.bat 完全一致**（同一脚本两份拷贝，均无提权块；设计 §9-3 双入口命名） |
| `build/maker/office-CLAUDE.md`（新） | 办公助手人格（中文文案向，写入 config\office\CLAUDE.md） |
| portal `usb-web/maker/` | 同步上述产物 |
| `tests/smoke.sh` | 增第 6 节：maker 产物断言 |

## 1. 阶段划分

### A1 网关复测（0.5h，可与其他项并行准备但不发版）
1. 带真 token 各打一次 `https://tokeneff.com/v1/responses`（`{"model":"glm-5.2","input":"你好"}`）与 `/v1/chat/completions`（空 POST 探测已过：401 路由全通）；
2. 取真 token（走制作器同款邮箱验证流程签发测试 key，或用户提供）各打一次 `{"model":"glm-5.2","input":"你好"}`；
3. 若 codex.exe 可得（GitHub Releases 官方源），本机 `CODEX_HOME=临时目录` 起真实会话一次。
- 验收：两条 200 + codex 会话输出非空。**不通则 A3 顺延**（A2/A4 的 Claude 部分不受阻）。

### A2 启动器改造（3h）
改造点（repair-on-windows.ps1）：
1. **菜单先于提权**：现流程「.bat 双击即提权（bat:15-20）→ ps1 UAC 自检（63 行起）→ … → 主菜单 Read-Host（566 行，顶层代码非函数）」。改为：**两侧同步**——bat 删提权块后直接调 ps1；ps1 入口先出模式菜单（不自动提权）：
   ```
   [1] 维修模式（需管理员权限，处理系统级问题）
   [2] 办公助手模式（无需提权，写文档/表格/文案）
   [3] 查询余额 / 管理账号
   [0] 退出
   ```
   选 [1] 时才 `Start-Process -Verb RunAs` 重入自身（沿用现有 `-Elevated` 参数防循环，不新造参数名）；拒绝 UAC → 降级只读诊断模式（沿用现 63-75 行语义）。**存量盘兼容**：agents.json 不存在 → 全按现状（claude 在则用、菜单不出现 Codex 项），新旧 ps1 均兼容。[2]/[3] 全程普通权限。
2. **办公助手模式**：启动 claude 时注入 `config\office\CLAUDE.md` 内容（用现成已验证的 `--append-system-prompt` 参数，ps1:463/467 已有先例；**不用** `--settings`——那是 JSON 设置文件不承载人格），人格 = 中文办公助手（千字级文案、Excel 公式、邮件润色；**不做系统改动**，遇系统问题引导回 [1]）；免提权 + 余额页共用；
3. **Codex 入口**（若 A3 完成）：菜单加「[x] Codex CLI」项；`agents.json` 解析：`installed=true` 才列出；`userDeclined=true` → 灰色行「未安装（重跑制作命令可补装）」不启动；两者皆无 → 隐藏；
4. **取消 Claude 的盘**：agents.json 里 claude `userDeclined` → 入口仍可开，但选 [1]/[2] 提示「此盘未安装 Claude 引擎，重跑制作命令可补装」，**不触发在线安装回落**；
5. 版本 0.2.0 → 0.3.0。
- 验收（本机可测部分）：PS 5.1 语法解析过（`powershell -NoProfile -Command "{}"` 无法本机测，用 `pwsh -NoProfile -c "[scriptblock]::Create((Get-Content -Raw x.ps1))"` 或 ast 解析）；菜单/UI 用 Pester 或 dry-run 手查；真机验收归 K1a。

### A3 Codex 集成（2h，依赖 A1 通过）
1. **下载源**：GitHub Releases `openai/codex` 官方 `codex-x86_64-pc-windows-msvc.exe`（zip 或 exe，实现时以 Releases 实际产物为准），钉 sha256（发布侧 digest），落 manifest 组件表 `codex.exe`；
2. **制作器新增第 6.6 步**（勾选了 codex 才走）：Temp 下载 → sha256 校验 → mv 到 `bin\codex.exe`（沿用便携 claude 模式）；
3. **配置落盘** `config\codex\config.toml`（移植 onboard.py:488 模板，路径参数化）：
   ```toml
   model_provider = "tokeneff"
   model = "glm-5.2"
   [model_providers.tokeneff]
   name = "tokeneff gateway"
   base_url = "https://tokeneff.com/v1"
   env_key = "TOKENEFF_API_KEY"
   wire_api = "responses"
   ```
4. **启动器启动 Codex**：`CODEX_HOME=<U盘>\config\codex` + `TOKENEFF_API_KEY=<auth_token>` 注入 env，PATH 前置 `bin\`（复用 PortableGit 的 PATH 段）；**写配置前先验证**（curl /v1/responses 一次，失败不落盘——沿用 onboard 模式，但 U盘 侧制作器已在邮箱验证时验证过网关，此处仅启动器首次启动时验证）；
5. agents.json 记 `{"codex":{"installed":true,"version":"<x.y.z>"}}`。
- 验收：制作器干跑（mock 下载或真下载）产出 bin\codex.exe + config\codex\config.toml；smoke 断言。

### A4 制作器勾选交互（4h，核心）
1. **勾选步骤插入**（两侧）：Win ISO 选择（ps1 第 5 步 ~403 行）之后、组件下载（第 6 步 ~415 行）之前。ps1：编号多选（Read-Host → split '[，, ]' → 去重 → 校验 1-5 → 非法重 prompt，回车默认 [1]）；sh：`--agents claude,codex,linux` 参数优先，缺省逐项 y/n 问答；
   - P-A 期菜单实际可选项：`[1] Claude Code`、`[2] Codex CLI`（A1 通过才出现，否则提示「Codex 暂不可用已跳过」且 **agents.json 不记 codex 条目**——语义同「下载失败未装=隐藏」）、`[5] Linux 安装镜像 Debian 12 ~650MB`；[3]/[4] 不列；**PortableGit/MinGit 为 [1][2] 共用**：任一勾选即安装（现 claude 直跑已依赖，语义不变）；
2. **容量预检拆两段**（MinDiskGB 在磁盘枚举/选择阶段（ps1:358/365/389/390）就用作过滤，先于勾选——不能简单替换）：
   - **选盘前**（枚举过滤）：基础门槛改为 `MinBaseGB = 5`（Live 1.4 + 组件 0.5 + Ventoy /R:2048 保留 2 + 余量 1），沿用现有枚举/选择/校验逻辑，仅换常量与提示文案；
   - **勾选后**（Win ISO 已选、agent 勾选完成、下载前）：动态复查 `5GB + WinISO + Σ勾选项（codex 334MB / Debian 650MB / node 110MB(P-B)）`；不足时打印「建议取消项」列表（优先 Debian → Win ISO → codex），允许：继续（自负）/ 重选 / 退出；sh 侧同构两段。
3. **下载范围裁剪**：内存中的组件下载列表按勾选过滤；新增 Debian 12 netinst 步骤（官方 CDN 直链 + 官方 SHA256SUMS 钉值 → 校验 → `ISO\debian-12-netinst.iso`）；
4. **第 10 步盘上复核循环扩展**：现复核项（ventoy/claude/settings 等）基础上纳入——勾选 codex：`bin\codex.exe` + `config\codex\config.toml` 存在；勾选 Debian：`ISO\` 内文件名匹配 + sha256 复核；未勾选项**不得**因缺失报错；
5. **agents.json / isos.json 生成**（挂载后、token 步骤附近）：`{"claude":{"installed":bool,"userDeclined":bool},"codex":{…}}`、`{"debian":{"filename":"…","sha256":"…","source":"…"}}`；下载失败降级时 installed=false 且 userDeclined=false（→ 启动器隐藏）；
6. **ventoy.json**：勾选 Debian 时 menu_alias 增 `"/ISO/debian-12-netinst.iso" => "安装 Debian 12"`；
7. **AI-Workstation.bat**（新）：与改造后 repair-on-windows.bat 逐字节一致（cp 复制）；制作器两文件都投放；**存量盘的旧 bat 仍自动提权属已知并接受**（无法远程改写，其行为只是多一次 UAC 弹窗，不破坏新逻辑）；
8. **manifest**：发布侧 manifest.json 增 codex.exe 组件条目（url/sha256/sizeBytes），**不按勾选改写**（裁剪只发生在制作器内存下载列表）；usb-web 手动下载页**经核查无需裁剪**——该页是静态站、读不到盘上 agents.json/isos.json，且本就全列组件由用户自选下载；设计 §4.0「按 isos.json/agents.json 过滤」实指未来按需展示，**P-A 显式延后（设计文同步加「展示层，P-C」标注）**；
9. 版本 usb-v1.0.ps1/sh 1.1.0 → 1.2.0。
- 验收：`--agents claude` 干跑（下载步骤 mock）勾选菜单/容量预检/agents.json 输出正确；smoke 断言（见 §2）。

### A5 同步与冒烟（1h）
1. `build/maker/` → portal `usb-web/maker/` 同步（注意 charset utf-8 既有坑）；
2. smoke.sh 增第 6 节断言（见 §2）跑绿；
3. 真机制作一根全勾选盘留给用户 K1a（A1 复测通过后）。

## 2. smoke.sh 新增断言（第 6 节）

先跑基线记录当前数字（v0.3 期为 22 项）。新增：
1. 两制作器不再有硬编码 `MinDiskGB = 8` / 8GB 字样（选盘前门槛改 `MinBaseGB = 5`，动态复查逻辑存在——grep `MinBaseGB` 与「复查」变量名判定）；
2. `usb-v1.0.sh` 支持 `--agents`（`grep -- '--agents'`）；
3. 两制作器均含 `agents.json` 与 `isos.json` 写入字样；
4. 提权重构：两个 .bat 均无 `-Verb RunAs`/`net session`（提权块已删）；ps1 中 `-Verb RunAs` 仅出现在维修模式分支内（**锚文本序断言**：菜单提示字符串的行号 < RunAs 行号，不依赖行号常量，容忍代码挪动；主菜单是顶层代码，不预设函数化重构）；
5. `config.toml` 模板含 `wire_api = "responses"` 与 `base_url = "https://tokeneff.com/v1"`；
6. `AI-Workstation.bat` 与 `repair-on-windows.bat` 内容一致（cmp 判定）且均调 repair-on-windows.ps1；
7. ventoy.json 生成段含「安装 Debian 12」别名分支（grep Debian 变量化条件）。

## 3. 回滚

git（两仓）按文件级回退：ai-repair-usb 仓 `build/maker/` 6 文件（ps1/sh/launcher-ps1/两个 bat/office-CLAUDE.md）+ `tests/smoke.sh` + 本计划；token-efficiency 仓 `portal/usb-web/maker/` 同步副本（回滚 = 重新从 build/maker 同步旧版或 git checkout）；ISO 不重建（P-A 不动 build/live 树，v0.3 ISO 不受影响）。

## 4. 风险与备注

- 网关域名是 `tokeneff.com`（nginx /v1/ 代理），**不存在 api 子域**——代码/文档中不得出现 `api.tokeneff.com`（本计划已两轮纠正，smoke 断言 5 兜底）；
- codex.exe 体积 ~334MB，全勾选盘容量预算见设计 §4.0（动态预检兜底）；
- PS 5.1 无 AST 解析依赖的语法特性慎用（菜单解析用基础 split/trim）；
- `.bat` 投放双入口：AI-Workstation.bat 与 repair-on-windows.bat 内容一致仅命名不同（存量盘兼容 + 新入口，设计 §9-3）。

## 5. 修订记录

- v1.1（2026-10-15）：按审计（0 阻碍 + 3 主要 + 4 次要）修订——①bat 侧提权块删除纳入文件表，AI-Workstation.bat 与改造后 bat 逐字节一致（消除三种矛盾说法），存量盘旧 bat 自动提权记录为已知接受；②容量预检拆两段（选盘前 MinBaseGB=5 常量替换 + 勾选后动态复查）；③usb-web 手动下载页显式决策延后 P-C（设计文同步标注）；次要：smoke 断言 1/4/6 重写为可判定（断言 4 改锚文本序）、MinGit 共用语义写明、codex/Debian 纳入第 10 步盘上复核、回滚清单修正为 6 文件 + portal 侧说明、网关阻塞表述更新（网关已实测通）；吸收报告新细节：A2 人格注入改用 `--append-system-prompt`（--settings 不承载提示词）、提权重入沿用现有 `-Elevated` 参数名、存量盘无 agents.json 时按现状兼容、A1 失败时 agents.json 不记 codex 条目。
- v1.0（2026-10-15）：首版。
