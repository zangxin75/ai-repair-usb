# repair-on-windows.ps1 · RDD 需求表与测试清单

- 创建日期：2026-10-13
- 依据：技术方案_AI电脑维修U盘_场景三Windows在线维修新增功能_20261013.md V1.2（功能 1/3/4、5.1/5.3/5.4/5.5）；实施计划 W1/W2
- 交付物：`build/maker/repair-on-windows.ps1` + `build/maker/repair-on-windows.bat`
- 流程纪律：本文件需求表与测试清单**先于**代码定稿（RDD）；代码实现逐条对应 R 编号

---

## 一、需求表（每条可测）

### A. 入口与权限

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R1 | bat 双击入口自动请求 UAC 提权后调 ps1（标准自提升模式） | 非管理员双击 bat → 弹 UAC → 同意后 ps1 以管理员运行（标题栏/whoami 可证） |
| R2 | ps1 直接运行时也自检并自提升（Start-Process -Verb RunAs 重启自身） | 非管理员直接运行 ps1 → 弹 UAC → 同意后进入主流程 |
| R3 | 用户拒绝 UAC → 不退出报错，进入**只读诊断模式**（菜单仅开放只读诊断/余额查询/退出，维修会话禁用并说明原因） | UAC 点"否" → 脚本继续运行且菜单中"维修会话"项提示需提权不可选 |
| R4 | 提权成功 → 全功能菜单（只读诊断/维修会话/余额查询/退出） | 管理员运行 → 4 个菜单项全部可用 |

### B. 盘符定位与配置解析（方案 5.1）

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R5 | 以脚本自身所在路径定位U盘根目录，再定位 `/config/` | 脚本放U盘根运行 → 输出的U盘根与 config 路径正确 |
| R6 | `$PSScriptRoot` 无 config 子目录（放错位置/网络路径运行）→ 中文报错退出 | 把 ps1 拷到本地盘运行 → 提示"未找到 config 目录" |
| R7 | settings.conf 解析：剥离整行注释（`#` 开头）→ 逐行按首个 `=` 切分 KEY/VALUE → 值不加引号、等号两侧无空格 | 用含整行注释的样例 conf 解析出的 hashtable 与预期一致；含 `KEY = VALUE`（带空格）或行内注释的行不产生错误键值（带空格行按原文切不出有效对即忽略/告警） |
| R8 | 缺 ACTIVATE_URL/BALANCE_URL 等必需键 → 中文报错 | 删掉 ACTIVATE_URL 行 → 启动时提示配置缺失 |
| R9 | key 从 `/config/auth_token` 读取（trim 换行/空白），不写 settings.conf | auth_token 有值 → 不触发激活流程 |

### C. 激活流程（方案 5.4/5.5，API 网关未实现，按契约编码）

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R10 | auth_token 缺失 → 激活流程：收集 U盘序列号（USB 所在物理盘 SerialNumber） | 无 auth_token 启动 → 日志输出采集到的非空 SN |
| R11 | 机器指纹：`Get-CimInstance Win32_BaseBoard \| Select SerialNumber` 优先，失败（如 Win10 早期 CIM 异常）兜底 `wmic baseboard get serialnumber` | Win11 24H2（无 wmic）走 CIM 成功；模拟 CIM 失败 → 走 wmic；两者皆失败 → 指纹置 "UNKNOWN" 不阻断激活（fp 仅观察字段） |
| R12 | 可选推广码输入（回车跳过；settings.conf 已有 PROMO_CODE 则作默认值） | conf 有 PROMO_CODE=ABC → 提示默认 ABC 回车即用；无 → 回车跳过 |
| R13 | `POST {ACTIVATE_URL}` body `{usb_sn, machine_fp, promo_code?, maker_version}`（maker_version 读U盘根 maker_version 文件，缺省 "unknown"） | 抓包/mock 均值验证 body 字段齐全 |
| R14 | 激活成功 200 → key 写回 `/config/auth_token`（无 BOM/无引号/末尾换行），`BATCH_ID=` 写入 settings.conf（有则更新，无则追加） | 激活后U盘两文件内容正确；重复激活不重复追加 BATCH_ID |
| R15 | 同 SN 幂等 200（返回原 key）→ 行为与首次激活一致（写回+提示） | mock 返回 200 带 key → 正常写入，无报错 |
| R16 | 429（IP 当日超限）→ 中文提示"该网络今日激活次数已达上限，请明日再试或联系支持"，阻断并引导场景② | mock 429 → 显示对应提示后走场景②引导 |
| R17 | 403（SN 校验失败/黑名单）→ 中文提示"U盘序列号校验失败，请通过官网渠道重新制作U盘"，阻断并引导场景② | mock 403 → 对应提示 |
| R18 | 423（SN flagged/suspended）→ 中文提示"该U盘已被风控暂停，请联系支持"，阻断并引导场景② | mock 423 → 对应提示 |
| R19 | 409（key 过期）→ 中文提示"免费额度有效期已过，请走付费/续费通道"，读U盘升级 URL 引导 | mock 409 → 对应提示 + 升级 URL |
| R20 | 激活网络失败/网关不可达 → 重试 2 次（共 3 次尝试）→ "网关暂不可用" + 引导场景② | 断网/mock 超时 → 观察 3 次尝试后场景②引导文案 |
| R21 | 并发激活（同 SN 双方同 key）为网关侧行为，客户端按普通 200 处理 | mock 200 同 key 两次 → 均正常 |

### D. 余额与验证（方案 5.4/5.5）

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R22 | 每次启动（含已有 key）调 `GET {BALANCE_URL}`（Authorization 头携带 key） | 启动日志可见 balance 请求；返回值展示剩余额度 |
| R23 | `verification_required=true` → 终端内验证：输邮箱 → `POST /verify` `{key,email}` → 提示收码 → 输码 → `POST /verify/confirm` `{key,code}`；confirm 成功后继续，失败给中文提示（码错/过期）可重试 | mock 触发标志 → 走完输邮箱→输码流程；mock confirm 400 → 提示后可重输 |
| R24 | 余额 <10%（remaining_weekly / weekly 配额估算，无法估算时仅展示绝对值不误报）→ 菜单上方黄色提示 | mock remaining=5% → 显示低余额提示 |
| R25 | 余额用尽（remaining_weekly ≤ 0）→ 软着陆：不进入维修会话，提示额度已用完，读U盘根预置升级 URL 文件（如 `upgrade-url.txt`）显示升级入口 | mock remaining=0 → 显示升级 URL，维修会话项禁用 |
| R26 | balance 网络失败 → 重试 2 次 → 提示网关暂不可用并引导场景②（③完全依赖网关，阻断） | 断网 → 3 次尝试后阻断引导 |

### E. claude 运行时

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R27 | `CLAUDE_CONFIG_DIR`：启动会话前从U盘 `/config/claude-config/` 复制到 `%TEMP%\ai-repair\claude\`，环境变量指向该目录；源目录缺失则建空目录不报错 | 会话启动后 `$env:CLAUDE_CONFIG_DIR` 为 %TEMP%\ai-repair\claude\；目录内容与U盘一致 |
| R28 | 绝不覆写 `%USERPROFILE%\.claude\`（脚本无任何针对该路径的写操作） | 代码审查 + 运行前后该目录 mtime/内容不变 |
| R29 | `ANTHROPIC_BASE_URL`（取 settings.conf GATEWAY_BASE_URL，缺省 https://tokeneff.com）与 `ANTHROPIC_AUTH_TOKEN`（=key）仅注入本进程及子进程环境变量，不落盘用户电脑 | 会话进程内可见两变量；脚本退出后系统/用户环境变量无残留 |
| R30 | `claude` 命令检测：`Get-Command claude`；无 → `irm https://claude.ai/install.ps1 \| iex` 安装，失败重试 2 次（间隔 10s） | 干净 Win11 → 自动安装成功并可启动会话 |
| R31 | 安装 3 次均失败 → 中文原因诊断指引（安全软件拦截→引导加白名单 / 代理网络 / 磁盘空间 / PowerShell 执行策略）→ 兜底引导场景②离线维修 | mock 安装失败 → 显示四类指引与场景②文案后退出 |
| R32 | claude 检测/安装属会话前置步骤：激活与 balance 在其之前完成（方案 5.3 网关不可达独立降级优先阻断） | 断网时先报网关不可达，不进入安装步骤 |

### F. 菜单与会话

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R33 | 主菜单用 PS 编号选择循环（whiptail 不存在于 PS），中文，含：[1] 只读诊断 [2] 维修会话 [3] 余额查询 [4] 退出（退出清理后收尾） | 菜单可循环选择，无效输入提示重输 |
| R34 | 维修会话：以U盘 `CLAUDE.md`（存在时）为系统提示词启动 claude 交互会话；无 CLAUDE.md 用 /config/claude-config/CLAUDE.md；均无则直接启动 | 会话启动后系统提示词生效（claude 输出身份符合U盘 CLAUDE.md） |
| R35 | 只读诊断：以"只读诊断，禁止任何写操作"约束的提示词启动 claude 会话 | 未提权场景仅此路径可进；会话内 claude 声明只读约束 |

### G. 退出清理（功能 4 / W4 前置）

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R36 | 退出时删除 `%TEMP%\ai-repair\`（含 claude 配置临时副本），失败仅告警不报错 | 退出后目录不存在 |
| R37 | 会话历史（临时 CLAUDE_CONFIG_DIR 下 projects/）随 R36 一并清理（customer 语义）；`RECORD_MODE=enterprise` 时脚本仅**提示**"会话历史按企业模式保留，由收尾任务决定"，仍只清理配置副本本身之外不动作——脚本不硬编码删除本地记录（方案定稿：清理动作由收尾任务文本驱动） | enterprise 模式退出 → 显示保留提示；customer 模式 → R36 清理覆盖临时副本 |
| R38 | 退出时清除本进程环境变量中的 key（进程退出即消亡，脚本显式置空以示意） | 代码审查：退出路径 `$env:ANTHROPIC_AUTH_TOKEN=$null` |

### H. 工程约束

| 编号 | 需求 | 可测判据 |
|------|------|---------|
| R39 | 兼容 PowerShell 5.1+（Win10/11 自带），`#requires -Version 5.1`；仅 .NET 内置 + Invoke-RestMethod/Invoke-WebRequest，不引入外部 PS 模块 | PSScriptAnalyzer 零 error；无 Import-Module 非内置模块 |
| R40 | 代码风格与 usb-v1.0.ps1 一致：中文注释、`$ErrorActionPreference='Stop'`、Write-Step/Write-Ok/Write-Warn/Write-Fail/Die 工具函数同款 | 人工比对 |
| R41 | 输出编码：控制台 UTF-8 输出 chcp 65001 前置（bat 内设置），中文不乱码 | 双机运行中文显示正常 |

> 需求表共 **41 条**（R1–R41），覆盖技术方案功能 1/3/4 与 5.1/5.3/5.4/5.5 全部启动器侧行为。

---

## 二、Windows 10/11 双机手动测试清单

> 本机为 Linux 开发机，无 Windows：以下全部**待 T1 真机执行**。
> 测试机：A = Win11 24H2（验 Get-CimInstance 路径，wmic 已移除）；B = Win10 22H2（验 wmic 兜底可用性与 PS 5.1 兼容）。
> 网关 /api/usb/* 未实现前，用 mock（hosts 指向本地 mock 服务或改 settings.conf URL 指向 mock）驱动 R13–R26。

### 准备

- [ ] P-1 制作一只含新数据分区布局的U盘（settings.conf/claude-config//maker_version/upgrade-url.txt；若 S0 未接线，手工放置样例文件）
- [ ] P-2 mock 服务：/activate 可按脚本返回 200/200 幂等/429/403/423/409；/balance 可控 remaining 与 verification_required；/verify、/verify/confirm 各 200/400
- [ ] P-3（待有 pwsh 环境）语法静态检查：`pwsh -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw repair-on-windows.ps1))"`；有条件再跑 PSScriptAnalyzer 零 error（W1 验收项）

### 权限与入口（R1–R4）

- [ ] A-1 / B-1 非管理员双击 bat → UAC 弹窗 → 同意 → 主流程运行
- [ ] A-2 / B-2 非管理员直接运行 ps1 → 自提升同上
- [ ] A-3 / B-3 UAC 点"否" → 只读诊断模式：菜单可见但维修会话禁用并说明
- [ ] A-4 管理员运行 → 全功能菜单

### 定位与解析（R5–R9）

- [ ] A-5 / B-5U盘根运行 → 正确定位 config/
- [ ] A-6 / B-6 本地盘拷贝运行 → "未找到 config 目录"退出
- [ ] A-7 样例 conf（含整行注释、空 PROMO_CODE、BATCH_ID）解析正确
- [ ] A-8 删 ACTIVATE_URL → 配置缺失报错
- [ ] A-9 auth_token 含末尾换行 → trim 后可用

### 激活（R10–R21，mock 驱动）

- [ ] A-10 / B-10 无 auth_token → SN 与指纹采集日志（A 机证无 wmic 依赖；B 机可拔 wmic 验 CIM 优先）
- [ ] A-11 推广码：conf 有默认/无默认两分支
- [ ] A-12 mock 200 → auth_token 与 BATCH_ID 写回正确，二次启动不重复激活
- [ ] A-13 mock 429/403/423/409 → 四种中文提示分别正确，均引导场景②
- [ ] A-14 mock 超时 ×3 → "网关暂不可用"+场景②引导
- [ ] B-15 B 机模拟 CIM 失败 → wmic 兜底取到指纹

### 余额与验证（R22–R26，mock 驱动）

- [ ] A-16 每次启动 balance 请求与额度展示
- [ ] A-17 verification_required=true → 邮箱→收码→输码全流程；错误码可重试
- [ ] A-18 remaining 5% → 低余额提示
- [ ] A-19 remaining 0 → 软着陆 + 升级 URL 展示
- [ ] A-20 balance 断网 ×3 → 阻断引导场景②

### claude 运行时（R27–R32）

- [ ] A-21 / B-21 会话前 %TEMP%\ai-repair\claude\ 副本生成，CLAUDE_CONFIG_DIR 指向正确
- [ ] A-22 / B-22 运行前后 %USERPROFILE%\.claude\ 未被修改（记录目录 hash 对比）
- [ ] A-23 干净 A 机（无 claude）→ 在线安装成功
- [ ] A-24 mock 安装失败 ×3 → 四类原因指引 + 场景②兜底
- [ ] A-25 断网 → 网关阻断先于安装步骤

### 菜单/会话/清理（R33–R38）

- [ ] A-26 / B-26 菜单循环、无效输入、四项功能逐项验证
- [ ] A-27 维修会话系统提示词来自U盘 CLAUDE.md
- [ ] A-28 只读诊断会话约束生效
- [ ] A-29 / B-29 customer 模式退出 → %TEMP%\ai-repair\ 已删、无 key 残留（环境变量/落盘检查）
- [ ] A-30 enterprise 模式退出 → 显示保留提示，本地记录未被脚本删除
- [ ] B-31 B 机中文输出不乱码（R41）

### 收尾核查（T1 拔盘残留）

- [ ] T-a customer 模式拔盘后电脑无维修痕迹人工核查（W4 验收联动项）

---

## 三、已知限制与遗留

- API 网关 /api/usb/* 未实现（S2/S3），R13–R26 全部依赖 mock，待 M1（S2 上线）后真机联调
- 制作器 S0 接线（settings.conf/claude-config//maker_version/upgrade-url.txt 初始落盘）另行任务，本清单 P-1 用手工样例替代
- 本机无 pwsh：语法静态检查与 PSScriptAnalyzer 待有 pwsh 环境补跑（P-3）
- W3（记录系统/指纹召回目录准备）不在本次交付范围，R34 提示词仅含 CLAUDE.md 注入
