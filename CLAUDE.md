# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

AI 电脑维修 U盘：Ventoy 多启动 U盘 + 定制 Debian 12 Live ISO（内置 Claude Code，经 tokeneff.com 网关接入）+ Windows 10/11 镜像。启动后自动进入中文交互界面（选择式菜单优先，对话兜底），服务家庭维护/上门维修/装机部署三类用户。

**权威文档**（改代码前先读）：
- `04-技术方案/技术方案_AI电脑维修U盘_总体设计_20260912.md` — 总体设计 V1.5 定稿（三轮 critic 审计）
- `05-执行工具/实施计划_AI电脑维修U盘_20260912.md` — 实施计划 V1.4 定稿（P0~P8 阶段划分）
- `01-项目规划/README.md` — 项目索引与进度

## 常用命令

```bash
# 冒烟测试（在 05-执行工具/ 下运行，mock 夹具，不碰真机）
bash tests/smoke.sh

# 构建机准备（Debian 12 实体机/VM；WSL2 不能跑 lb build——缺 loop 设备）
sudo bash setup-build-host.sh

# 构建 ISO（在构建机上；当前构建机为 构建机，见下）
cd live-build-config && sudo bash build.sh          # 完整构建
cd live-build-config && sudo bash build.sh --deps   # 只准备离线组件（Node/claude-code），不出 ISO

# 静态检查
bash -n <script>          # 语法检查所有 .sh
shellcheck <script>       # lint
```

## 构建机 构建机（SSH 接入）

`ssh 构建机`（本机 `~/.ssh/config` 已配别名；经 Tailscale，本机 tailnet IP 【内网地址】）。
- Debian 12，用户 `ops`，免密 sudo；工作区 `~/ai-repair/`
- 接入细节与排雷记录：`06-会议记录/构建机接入记录_构建机_20260912.md`
- p1（【内网地址】）**不能**直连 163；243（te-prod-app-01, 【内网地址】, 用户 kt）是凭证跳板

## 代码架构（三个层次）

```
05-执行工具/
├── build/live/usr/local/bin/    # Live 端维修脚本【权威源】——welcome.sh 是编排入口
├── build/live/usr/local/share/tasks/  # 菜单选项 → claude 初始提示词文本
├── build/live/etc/skel/.claude/CLAUDE.md  # Live 内 AI 的系统提示词（与 live-build-config 内副本必须保持一致）
├── build/maker/                 # 一键制作器：usb-v1.0.ps1（Win）/ usb-v1.0.sh（Linux）+ manifest.json + index.html
├── live-build-config/           # Debian Live ISO 构建配置（auto/config、hooks、package-lists、includes.chroot）
└── tests/smoke.sh               # mock 冒烟测试（R8a 要求）
```

**关键架构决策**（违反会破坏功能）：

1. **启动编排链**：Live 启动 → `welcome.sh`（5 步：挂载数据分区→五级网络诊断→凭证 export→说明→主菜单）→ `main-menu.sh`（whiptail 6 选项）→ `exec claude "$(cat tasks/X.txt)"`。环境变量必须在挂载 exFAT 数据分区**之后**在 welcome.sh 内显式 export（不能用 profile.d——时序 bug）。
2. **脚本与 AI 的职责边界**：确定性行为（编号菜单、二次确认、进度显示）全部由脚本实现；`etc/skel/.claude/CLAUDE.md` 只约束对话风格。任务文本首行必须是「（系统流程，请直接开始执行，不要复述任务）」前缀（smoke.sh 会检查）。
3. **网关接入**：`ANTHROPIC_BASE_URL=https://tokeneff.com`；连通性探针 = `POST /v1/messages`，**HTTP 4xx 算通过**（可达需鉴权），5xx/超时算失败。上游实际模型是 GLM 系列（网关做模型名映射）。
4. **Windows 装机两段式**：Linux 侧 `install-windows.sh` 只做 wimlib 灌装 + unattend.xml（写到 `\Windows\Panther\`），**不在 Linux 跑 bcdboot**（不存在）；引导修复由重启后进 WinPE 完成。
5. **破坏性操作防护**：目标盘选择用 `/dev/disk/by-id/usb-*` + `udevadm ID_BUS` 双重排除 U盘自身；whiptail 确认用 `--defaultno`（必须放在位置参数前）。
6. **持久化**：弃用 Ventoy persistence 插件，改用 exFAT 数据分区的 `/config/` 目录（凭证、claude-code 更新包 tar.gz——exFAT 不支持软链）。
7. **供应链红线**：Windows ISO 绝不自托管（Fido 式动态解析微软官方链接）；安装器 URL 版本化（/usb-v1.0.ps1）+ 发布 SHA256。

## 文档规范（用户全局 CLAUDE.md 强制）

- 新文档按类型入 `01-项目规划/ … 06-会议记录/`，命名 `[类型]_[项目名]_[日期].md`，不得放根目录
- 每篇文档含：创建日期 / 版本 / 状态 / 作者
- 关键交付物同步更新 `01-项目规划/README.md` 进度

## 审计工作流

设计/计划类文档落地前须过 critic 审计循环（本仓历史：设计 3 轮 6.0→8.5，计划 3 轮→8.5 ACCEPT）；代码交付须 verifier 独立复验（首轮 FAIL 修复后 PASS，冒烟 15/15）。
