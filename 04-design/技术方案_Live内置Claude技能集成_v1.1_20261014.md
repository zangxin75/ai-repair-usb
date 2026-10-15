# 技术方案：Live 内置 Claude 技能（Skills）集成

- 创建日期：2026-10-14
- 版本：v1.1（按 critic 审计意见修订：1 BLOCKER + 3 MAJOR，修订记录见文末）
- 状态：定稿——复审 ACCEPT（9/10，2026-10-14，剩 4 项 MINOR 已并入实施计划注意事项）
- 作者：kt + Claude Code

## 1. 背景与目标

Live 系统内的 AI 维修助手目前只有一份系统提示词（`etc/skel/.claude/CLAUDE.md`）约束行为。系统提示词适合放「全程有效」的原则（中文、大白话、危险操作确认），但不适合放「特定任务的操作流程」——全部塞进去会撑大每轮上下文，且无法按需加载、无法热更新。

Claude Code 的 Skills 机制（`~/.claude/skills/<名>/SKILL.md`）提供按需加载能力：技能描述常驻上下文（每条 1~2 行），正文只在任务匹配时载入。本方案利用该机制把维修领域知识结构化进 Live。

**目标：**
1. 补齐两类短板：排查方法论（防 AI 瞎猜乱试）与收尾验证（防 AI 假报修好）；
2. 沉淀维修领域流程知识（SMART 解读、数据抢救、重装前置检查、网络排障）；
3. 技能可通过 U盘 `/config/` 目录热更新，不重烧 ISO 也能升级。

**非目标：**
- 不改变现有脚本与 AI 的职责边界（确定性交互仍归脚本）；
- 不引入任何运行时依赖（技能是纯 Markdown，零安装成本）。

## 2. 技能清单（6 个）

| # | 目录名 | 来源 | 一句话定位 | 触发场景 |
|---|--------|------|-----------|---------|
| 1 | `systematic-debugging` | 改写自 obra/superpowers（MIT） | 四阶段排查：症状→假设→证据→结论，禁止无证据跳步 | 用户描述「电脑坏/慢/蓝屏/打不开」等模糊症状，需根因定位时 |
| 2 | `verification-before-completion` | 改写自 obra/superpowers（MIT） | 宣布修好前必须复验并展示证据 | 任何维修/修复/配置动作收尾时 |
| 3 | `smart-diagnosis` | 自写 | smartctl 报告解读→健康结论（好/警告/危险）+ 换盘建议 | 涉及硬盘健康、卡顿、异响、坏道、是否换盘时 |
| 4 | `data-rescue` | 自写 | 数据抢救决策树：先镜像后操作，testdisk/photorec 选择 | 误删文件、分区丢失/打不开、盘要坏了想捞数据时 |
| 5 | `reinstall-guardrail` | 自写 | install-windows.sh 前置检查清单 + 确认话术 + 后置验证 | 用户要重装系统/装新机时 |
| 6 | `network-triage` | 自写 | check-network.sh 五级结果的解释与兜底对话 | 上不了网、网关不通、AI 连接失败时 |

**上下文预算：** 6 条技能描述合计约 300~400 tokens（每条 description 控制在 60 字以内），正文每个 400~900 tokens 且按需载入。总常驻开销可接受。

**克制原则：** 技能总数上限 8 个。维修场景技能贵精不贵多，每加一个都要回答「不用它会发生什么错」。

## 3. 单个技能设计

### 3.1 systematic-debugging（排查四阶段）

改写自 superpowers 同名技能，本地化为维修场景、中文：

- **阶段一 症状采集**：问清「什么时候开始、变了什么、报什么错」；能自己查的不问用户（dmesg / journalctl / lsblk 先跑）。
- **阶段二 假设列举**：至少列 2 个竞争假设（如「硬盘坏」vs「系统文件损坏」），标注每个假设的预期证据。
- **阶段三 证据收集**：每个假设找一条可观测证据（SMART、日志、最小复现）；排除法推进，禁止「先试试看重装」。
- **阶段四 结论闭环**：结论必须能解释全部症状；解释不了的回到阶段二。
- **红线**：诊断阶段只做只读操作；写操作进入 CLAUDE.md 危险操作确认流程。

### 3.2 verification-before-completion（复验后才算修好）

改写要点（维修版）：

- 宣布「修好了」之前必须做一次**针对原症状**的复验（不是泛泛跑个命令）：修网络→真实连通测试；修启动→引导项实际核对；修文件→文件可读校验。
- 复验输出要给用户看得懂的证据（「刚才打不开的网页现在能打开了」级别）。
- 复验失败就明说没修好、回到排查，禁止「应该可以了」。
- 与 CLAUDE.md 的关系：CLAUDE.md 定原则（「先非破坏性诊断」），本技能定操作（怎么复验、展示什么证据），不重复条文。

### 3.3 smart-diagnosis（SMART 解读）

- 入口：优先调 `disk-check.sh`（已封装自检+坏道扫描）；需要细看原始报告时 `smartctl -a /dev/sdX`。
- 核心对照表（正文内嵌精简版）：
  - `Reallocated_Sector_Ct`、`Current_Pending_Sector` > 0 → 硬盘已出现坏块，处于劣化中；
  - `Power_On_Hours` 结合用户使用年限判断老化；
  - SMART overall HEALTHY 但用户报告卡顿 → 引导排查转向系统/温度/内存，不咬死硬盘；**内存检测遵守 CLAUDE.md 约定：不在 Linux 运行时测，引导用户重启选 MemTest86+**。
- 输出三档结论 + 建议：健康 / 警告（备份！短期内可能恶化）/ 危险（立即备份+换盘，不建议再装系统到该盘）。
- 关键纪律：**给「换盘」结论前必须先帮用户把数据备份方案排上**（衔接 backup-user-data.sh）。

### 3.4 data-rescue（数据抢救决策树）

- **第一原则：原盘只读。** 任何恢复操作前先评估：机械盘且异响 → 建议直接专业数据恢复机构（继续通电可能刮伤盘片）；普通场景 → 先 `ddrescue` 做整盘镜像到另一块盘，之后全部操作针对镜像做。
- 分支：
  - 分区丢失/分区表损坏 → testdisk（对镜像或只读模式分析）；
  - 误删文件/格式化 → photorec（按文件类型捞，先捞最要紧的类型，先小范围试捞评估成功率）；
  - 分区能挂载只是部分文件坏 → rsync 直接拷，坏文件跳过并记录清单。
- 输出：成功率预期（老实说，别给虚假希望）+ 目标盘剩余空间检查 + 捞出文件的位置。
- 与危险操作规则衔接：镜像写入目标盘属写操作，走 CLAUDE.md 确认流程。

### 3.5 reinstall-guardrail（重装护栏）

install-windows.sh 已有盘选择防护与二次确认，本技能补 AI 侧护栏：

- **前置清单（逐项核对后才调脚本）：**
  1. 数据已备份或用户明确确认放弃（问一句「桌面/文档/照片要不要保」）；
  2. 目标盘与用户口中的「系统盘」一致（让用户确认电脑型号/盘容量，防选错盘）；
  3. BitLocker 状态已检查（加密未解锁 → 先走 BitLocker 分支）；
  4. Windows 版本与激活方式确认（用户知道自己要装哪个版本）。
- **后置验证（衔接技能 2）：** 灌装完成 → 核对 unattend.xml 落位 `\Windows\Panther\`、wimlib 退出码、分区表状态；向用户交代「重启后由 WinPE 完成引导修复」这一两段式设计，管理预期。
- 话术要求：把「会清空整盘」翻译成用户语言（「C 盘 D 盘所有东西都没了」），确认一次即执行，不反复追问。

### 3.6 network-triage（网络排障兜底）

- check-network.sh 输出五级结果，本技能是**结果翻译器 + 兜底对话**：
  - L1 网卡未识别 → 驱动问题路径（lspci/lspci -k 看卡型号，firmware-misc-nonfree 已内置）；
  - L2/L3 IP/DNS → DHCP/路由器重启建议；
  - L4 互联网 → 代理/防火墙排查；
  - L5 网关 4xx/5xx → 区分「服务端问题等一等」vs「token 问题」，4xx-鉴权算通的既有约定要讲清楚（「服务是通的，只是需要钥匙」）。
- 兜底：脚本判不通但用户说能用 → 收集脚本原始输出分析，不硬套脚本结论。
- 离线模式提醒：AI 能力可能受限，本地脚本（体检/备份/密码重置）不依赖网络，优先引导。

## 4. 落地实现

### 4.1 文件位置与构建链

```
05-tools/build/live/etc/skel/.claude/skills/
├── systematic-debugging/SKILL.md
├── verification-before-completion/SKILL.md
├── smart-diagnosis/SKILL.md
├── data-rescue/SKILL.md
├── reinstall-guardrail/SKILL.md
└── network-triage/SKILL.md
```

- live-build 的 `includes.chroot` 同步机制已存在（build.sh 从 build/live 树 rsync），skel 下的新目录自动进 ISO，无需改构建脚本；
- live 用户首次开机由 live-config 从 skel 复制 home，技能随 `.claude/` 一并就位，无时序问题；
- **同步副本**：live-build-config 内的 CLAUDE.md 副本规则不变；skills 树同样需要在两处保持一致（build.sh 已整树同步，不额外维护）。

### 4.2 SKILL.md 格式规范

```markdown
---
name: smart-diagnosis
description: 硬盘健康诊断。涉及硬盘卡顿、异响、坏道、SMART 报告解读或是否换盘判断时使用。
---

（正文：流程 / 对照表 / 话术，中文，≤120 行）
```

- name 用英文 kebab-case（与目录名一致）；description 中文、首句点名用途、含触发场景关键词（技能匹配靠 description）；
- 正文全中文，面向终端里的 Claude 自用，不需要给用户看的排版；
- 单技能正文 ≤120 行（约 1~2K tokens），超出说明该拆分。

### 4.3 发布与更新策略（v1.1 修订：静态内置首发，热更新推后）

**v0.3 首发：技能只随 ISO 静态内置**（skel → live 用户 home，随 live-config 首次开机复制就位）。理由：
1. 审计确认原「复用 update-claude.sh 机制」不成立——update-claude.sh 是更新包的**生产者**（联网下载→打包写入 /config/），真正解包的是 welcome.sh（开机解到 /opt）；且 `~/.claude/skills/` 在 live 用户 home（overlay/tmpfs，重启即丢），任何「运行时解一次」的方案都会在下次开机静默回退 ISO 版；
2. v0.3 已带 token 签发 + 桌面直启两条新链路，首发面应收敛；
3. 技能变更频率远低于 claude 二进制，热更新收益低。

**热更新（预留设计，后续版本实现）**：U盘 `/config/claude-skills-<ver>.tar.gz`（内含 `VERSION` 文件防降级），由 **welcome.sh** 在第 1 步（挂载数据分区）之后、用户交互之前解包：解到临时目录校验（VERSION 高于当前才应用）→ 原子替换 `~/.claude/skills/`，失败保留原目录。update-claude.sh 可扩展为技能包的下载生产方（新增独立函数，不与 claude-code 版本比对的早退路径耦合）。**供应链要求**：技能包内容 = 注入维修 AI 系统提示的载荷（该 AI 有整机磁盘写权限），而 /config/ 在 exFAT 上用户可改，同盘 sha256 不构成防护——实现热更新时必须附发布侧签名（ISO 内置公钥校验）或 GPG 签名，否则不做热更新。

### 4.4 测试与验收

- `tests/smoke.sh` 增加 4 项可判定检查（v1.1 按审计细化）：
  1. 6 个 SKILL.md 全部存在、frontmatter 合法（name 与目录名一致、description 非空 ≤60 字）；
  2. 正文行数 ≤120；「连续 ≥4 个英文单词的行」数量为 0（可判定规则，防整段照抄 superpowers 未本地化；命令名/参数名白名单豁免）；
  3. **命令白名单校验**：从正文 grep 固定白名单（smartctl、ddrescue、testdisk、photorec、rsync、disk-check.sh、backup-user-data.sh、install-windows.sh、bitlocker-unlock.sh、check-network.sh、win-reset-password.sh、lshw、lsblk），命中即在 `package-lists/*.list.chroot` 与 `build/live/usr/local/bin/` 中核对存在，白名单硬编码进 smoke.sh；
  4. **负例触发**：data-rescue 的 description 不得含「重装」（防「要重装」误触发数据抢救流程）；reinstall-guardrail 的 description 不得含「坏道/异响」。
- K0 人工验收：真机起 Live，对话验证技能被正确触发（说「电脑很卡」应触发 systematic-debugging + smart-diagnosis）。

## 5. 风险与对策

| 风险 | 对策 |
|------|------|
| 技能描述常驻 6 条挤占上下文 | description 硬性 ≤60 字；smoke 校验；上限 8 个技能；K0 实机 `claude` 后用 /context 核对实际开销再定上限（Skills 元数据额外开销未实测） |
| 技能与 CLAUDE.md 规则冲突/重复 | 分层：CLAUDE.md 定原则，技能定操作；3.2/3.5 已显式划界 |
| 技能教唆危险操作（data-rescue 的 dd 镜像） | 技能正文显式引用 CLAUDE.md 危险操作确认流程为强制前置 |
| superpowers 改写偏离原方法论精髓 | 3.7 改写不变式（五条）；K0 时对照原 MIT 原文抽查 |
| 热更新的提示注入供应链风险 | v0.3 不做热更新（静态内置随 ISO）；热更新实现前必须解决签名校验（4.3） |
| exFAT 不支持软链 | 技能为纯 Markdown 无软链，不受影响 |

## 5.1 版本前提

Skills 按需加载是 claude-code 2.x 客户端机制（匹配发生在本地提示层，网关上游 GLM 不影响）。未来若更换/降级 Claude Code 打包，需回归验证技能仍被触发。

## 5.2 为什么用技能而不是写进 tasks/X.txt

任务文本是每任务强注入（选了菜单项就整段进上下文），技能是 description 匹配按需载入：通用方法论（排查流程）不属于任何单一菜单任务，强注入 8 个任务文本会 8 倍重复；而匹配式加载让「修启动」对话里不背「数据抢救」的流程。两者互补不替代。

### 3.7 superpowers 改写不变式（v1.1 补，审计 MAJOR-3）

改写为中文维修版时，以下五条从原方法论**原样保留**（只换措辞与例子，不改结构），K0 验收时对照原 MIT 原文抽查：

1. systematic-debugging 四阶段顺序不可换：症状采集→假设列举→证据收集→结论闭环；
2. 假设必须 ≥2 个且有预期证据（防单假设确认偏误）；
3. 诊断阶段只读，写操作须先过确认流程；
4. 结论必须解释**全部**症状，否则回到假设阶段；
5. verification-before-completion：复验针对**原症状**而非泛跑命令，证据须用户可读，失败即回排查、禁止「应该可以了」。

## 6. 审计裁定与遗留（v1.1：critic 三问裁定已采纳）

1. **技能先后关系**：不写互斥，用 description 次序表达——systematic-debugging 加「先于具体诊断的通用排查流程」短语，域技能（smart-diagnosis 等）描述具体症状词，方法论先行、域技能随后。
2. **热更新 vs 静态内置**：静态内置随 ISO 首发，热更新推后（见 4.3）。
3. **6 个一步到位**：方法论 2 个承担目标 1（防瞎猜/防假报修好）的一半价值主张，不拆。

**遗留到 K0**：实机记录 Skills 元数据真实上下文开销（/context）；负例触发验收（说「重装系统」不得命中 data-rescue，说「硬盘响」不得命中 reinstall-guardrail）。

**明确不做**：win-reset-password.sh 不配技能（脚本自带向导 + CLAUDE.md 脚本清单足够，克制原则，防后人误补）。

## 修订记录

- v1.0（2026-10-14）：初稿，送 critic 审计。
- v1.1（2026-10-14）：按审计修订——BLOCKER-1 §4.3 热更新机制重写（静态内置首发，热更新推后并给重设计+签名要求）；MAJOR-1 供应链风险入风险表与 4.3；MAJOR-2 smoke 检查细化为可判定规则（4 项含负例）；MAJOR-3 新增 3.7 改写不变式；MINOR 全采纳（MemTest86+ 衔接、上下文实测、版本前提、tasks/X.txt 对比、密码重置排除说明、负例验收）。
