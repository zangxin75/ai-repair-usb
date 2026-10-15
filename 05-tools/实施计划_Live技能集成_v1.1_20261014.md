# 实施计划：Live 内置 Claude 技能集成（v0.3 内容）

- 创建日期：2026-10-14
- 版本：v1.1（按 critic 首轮审计修订：4 MAJOR + 4 MINOR，修订记录见文末；critic 判定修完 4 MAJOR 可直接 ACCEPT）
- 状态：已修订，待复审
- 作者：kt + Claude Code
- 上游设计：`04-design/技术方案_Live内置Claude技能集成_v1.1_20261014.md`（复审 ACCEPT 9/10）

## 0. 范围与前置

**做**：6 个 SKILL.md 落入 `build/live/etc/skel/.claude/skills/`、smoke.sh 增 4 项检查、随 v0.3 ISO 构建发布、K0 真机验收。
**不做**：热更新通道（本期只留注释占位，welcome.sh/update-claude.sh 不动）；密码重置技能；WinPE/MemTest（P4.5 另行）。

**前置条件**：
- v0.2 已发布（manifest 1.0.2 在线）✅
- 桌面直启（ai-assistant.sh + Desktop 图标）已在 build/live 树中待随 v0.3 进 ISO ✅（v0.2 构建同步时点晚于文件创建，未包含，已验证）

## 1. 阶段划分

### S1 原文存档（0.5h）
- 取 obra/superpowers（MIT）的 systematic-debugging、verification-before-completion 原文落盘 `05-tools/research/superpowers-originals/`，附 LICENSE 副本（改写依据 + 版权合规 + K0 抽查对照）。
- 验收：两个原文文件 + LICENSE 存在。

### S2 编写 6 个 SKILL.md（4h，核心工作量，v1.1 按审计调估）

> 注意双源现状：`includes.chroot/etc/skel/.claude/CLAUDE.md` 是既有副本；本阶段在 `build/live/etc/skel/.claude/` 下新建 `skills/`，构建时经 build.sh 整树 cp 合并进 includes.chroot。
目录：`build/live/etc/skel/.claude/skills/<name>/SKILL.md`，内容严格按设计 §3.1~3.6 + §3.7 五条不变式。

硬性规格（逐文件自查 + smoke 把关）：
- name = 目录名（kebab-case）；description 中文、非空、≤60 字（`wc -m` 自查）、**设计 §2 表「触发场景」列关键词全部落进 description**（匹配靠 description）；
- systematic-debugging 的 description 含「先于具体诊断的通用排查流程」短语（次序表达，见设计 §6-1）；
- 正文全中文、≤120 行、连续 ≥4 英文单词的行 = 0（命令/参数白名单豁免）；
- 负例约束：data-rescue description 不含「重装」；reinstall-guardrail description 不含「坏道/异响」；
- data-rescue / reinstall-guardrail 正文显式引用 CLAUDE.md 危险操作确认流程为强制前置；smart-diagnosis 正文显式写「内存检测不在 Linux 运行时测，引导重启选 MemTest86+」。

产出顺序：先 2 个方法论（对照不变式逐条核），再 4 个域技能，最后交叉读一遍查重叠。

### S3 smoke.sh 增 4 项检查（1h）
**开工前先跑一次基线并记录数字**（审计实测当前为 16 项，不凭记忆写验收线）。

按设计 §4.4，落到 `tests/smoke.sh`，沿用现有 PASS/FAIL 计数风格，纯 bash+grep 无新依赖：

1. 存在性 + frontmatter（name=目录名、description 非空 ≤60 字）+ **恰好 6 个技能目录**（不存在第 7 个，防意外混入）；
2. 正文 ≤120 行；连续 ≥4 英文单词行 =0（豁免 = 白名单命令/参数，与检查 3 **共用同一份硬编码白名单变量**，防两处漂移）；
3. **命令白名单校验（命令→包名映射表 + 三类核查目标，v1.1 细化）**：
   - 核对 package-lists：`smartctl→smartmontools`、`ddrescue→gddrescue`、`photorec→testdisk`（testdisk、rsync、lshw、sensors、ntfs-3g 直名即包名）；
   - 核对 `build/live/usr/local/bin/`：disk-check.sh、backup-user-data.sh、install-windows.sh、bitlocker-unlock.sh、check-network.sh、win-reset-password.sh；
   - **仅豁免不做存在性核对**（基础系统隐式依赖，不在 package-lists 字面出现，grep 会误报）：lsblk、dmesg、journalctl、lspci、badblocks（disk-check.sh 内部调用）、ntfsfix、sensors；
   - 白名单只校验命令与 .sh；包名（如 firmware-misc-nonfree）出现在正文不校验。
4. 负例 description 禁词（同 S2 规则）。

验收：`bash tests/smoke.sh` 全绿（**基线 16 项 + 新 4 项 = 20/20**）；**故障注入自测**：① description 改超 60 字 → 检查 1 FAIL；② 删一个 SKILL.md → 检查 1 FAIL；③ 加第 7 个目录 → 检查 1 FAIL；④ 正文插一行 `Current_Pending_Sector > 0 硬盘已出现坏块` 这类含数字/属性名行 → 检查 2 不得误报（SMART 属性名下划线相连算 1 词）；⑤ 还原后 20/20。

### S4 v0.3 构建与发布（2h，多为等待）
1. 版本号三处同步：`build.sh` IMAGE_VERSION=v0.3 / IMAGE_DATE=**实际构建日**、`auto/config` --image-name 与 --iso-volume（v0.2 排雷教训：auto/config 忘改）；
2. 同步 build/live 树到 构建机（scp/rsync，含 skills/ + ai-assistant.sh + Desktop/）；同步后核对 构建机 侧 includes.chroot 里 skills 目录与本地一致（6 个 SKILL.md）；
3. 构建机 上清脏状态再构建，命令写死绝对路径（防 `~` 在 sudo 下展开为 /root）：
   ```
   ssh 构建机 'sudo rm -rf /home/ops/ai-repair/live-build-config/.build /home/ops/ai-repair/live-build-config/chroot /home/ops/ai-repair/live-build-config/binary*'
   ssh 构建机 'sudo sh -c "cd /home/ops/ai-repair/live-build-config && nohup bash build.sh > /home/ops/iso-build.log 2>&1 &"'
   ```
4. 产物校验：`sha256sum -c`；
5. **manifest 以线上 1.0.2 为基线**（v1.1 修订：仓库副本已陈旧停在 1.0.1/v0.1，不得从仓库副本编辑）：curl 拉线上 manifest → 仅改 ai-repair-live 条目（v0.3 文件名/sizeBytes/sha256/notes）与 generated 时间戳 → version 升 1.0.3 → 写回 portal/usb-web 与回填仓库 build/maker 副本 → usb-web 重建部署 → 线上 curl 验证（manifest + ISO HEAD 200 + size/sha256 一致）。

### S5 K0 真机验收（用户配合，0.5h）
- 烧 v0.3 到 U盘，起 Live，确认桌面图标存在；
- 正例：说「电脑很卡」应触发 systematic-debugging + smart-diagnosis；说「文件误删了」应触发 data-rescue；
- **负例（v1.1 措辞对齐设计 §6，消除歧义）**：说「重装系统」**不得命中 data-rescue**；说「硬盘有响声」**不得命中 reinstall-guardrail**（应命中 smart-diagnosis / data-rescue——机械盘异响属数据抢救分支）；
- `claude` 内 `/context` 记录 Skills 元数据真实开销，回填设计遗留清单；
- **§3.7 不变式抽查**：对照 S1 存档的 superpowers MIT 原文，抽查两个改写技能各 2 条不变式保留情况（阶段顺序、复验针对性优先）；
- 浏览器可打开（v0.2 修复回归确认）。

## 2. 验收总标准（Definition of Done）

1. smoke **22/22** 绿（S3 实测：基线 16 项 + 新节 6 条断言；故障注入 5 用例逐一验证 FAIL→还原→22/22）；
2. v0.3 ISO 构建成功、双端 sha256 一致、线上可下载且 manifest（1.0.3）指向正确；
3. K0 正负例触发全过 + /context 开销数据记录 + 不变式抽查通过；
4. 设计文档遗留清单回填、`01-planning/README.md` 进度更新；
5. 两仓变更待用户指令再 commit。

## 3. 风险与回退

| 风险 | 应对 |
|------|------|
| superpowers 原文获取失败（网络） | GitHub raw 失败换 jsdelivr/ghproxy；再失败降级：凭 §3.7 不变式 + README 描述改写，存档改记「原文未获取」 |
| 技能误触发/不触发（description 匹配差） | K0 负例即验收关卡；不过则只调 description 措辞（正文不动），重构建成本低 |
| v0.3 构建再踩脏状态/时序坑 | S4-3 强制清脏；auto/config 三处同步有检查清单 |
| 真机 K0 发现技能行为劣化 | **回退（v1.1 修正：build.sh 是 cp -a 合并拷贝，不删目标侧多余文件，只删源目录回退会静默失效）**：删 `build/live/etc/skel/.claude/skills/<name>/` 后，必须**同时** `rm -rf live-build-config/config/includes.chroot/etc/skel/.claude/skills`（本地与 构建机 两侧），再重出 v0.3.1。本期不改 build.sh 为 rsync --delete（避免影响 includes.chroot 内手工产物，改动留待后续单独评审） |
| 上下文开销超预算（>800 tokens 常驻） | 砍 description 到 40 字内；仍超则减技能数（先撤 network-triage，其兜底价值最低，check-network.sh 输出已自解释） |

## 修订记录

- v1.0（2026-10-14）：初稿送审。
- v1.1（2026-10-14）：按首轮审计修订——MAJOR-1 DoD 基线改实测 16→20/20 并要求开工先跑基线；MAJOR-2 回退步骤补 includes.chroot 侧删除（cp -a 合并拷贝陷阱）；MAJOR-3 负例措辞对齐设计 §6；MAJOR-4 manifest 以线上 1.0.2 为基线重写并回填仓库副本；MINOR 全采纳（白名单补 lspci/journalctl/badblocks 等并分三类核查目标、双源现状提示、nohup 绝对路径、白名单不校验包名、IMAGE_DATE 实际构建日、恰好 6 目录约束、故障注入加 SMART 属性名用例、S2 调估 4h）；不变式抽查补进 S5。

## 4. 审计关注点（提交 critic）

1. S3 白名单映射表是否完备（漏命令 = 漏检）；
2. S2 规格是否可验收（有无「写好再看」式的模糊标准）；
3. S4 发布流程与 v0.2 实际操作是否一致（有无凭记忆多写/少写步骤）；
4. 工作量估算合理性（总计 ~7h 含等待）。
