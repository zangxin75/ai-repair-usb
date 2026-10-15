# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

AI 电脑维修 U盘：Ventoy 多启动 U盘 + 定制 Debian 12 Live ISO（内置 Claude Code，经 tokeneff.com 网关接入）+ Windows 10/11 镜像。启动后自动进入中文交互界面（选择式菜单优先，对话兜底），服务家庭维护/上门维修/装机部署三类用户。

**权威文档**（改代码前先读）：
- `04-design/技术方案_AI电脑维修U盘_总体设计_20260912.md` — 总体设计 V1.5 定稿（三轮 critic 审计）
- `05-tools/实施计划_AI电脑维修U盘_20260912.md` — 实施计划 V1.4 定稿（P0~P8 阶段划分）
- `01-planning/README.md` — 项目索引与进度

## 常用命令

```bash
# 冒烟测试（在 05-tools/ 下运行，mock 夹具，不碰真机）
bash tests/smoke.sh

# 构建机准备（Debian 12 实体机/VM；WSL2 不能跑 lb build——缺 loop 设备）
sudo bash setup-build-host.sh

# 构建 ISO（在构建机上；当前构建机为 构建机，见下）
cd live-build-config && sudo bash build.sh          # 完整构建
cd live-build-config && sudo bash build.sh --deps   # 只准备离线组件（Node/claude-code），不出 ISO

# 静态检查
bash -n <script>          # 语法检查所有 .sh
shellcheck <script>       # lint

# 产物（已构建 v0.1，1.4GB，双端 sha256 已校验）
dist/AI-Repair-Live-v0.1-20260912.iso + .sha256（git 忽略 *.iso，产物不入库）
```

## 构建机 构建机（SSH 接入）

`ssh 构建机`（本机 `~/.ssh/config` 已配别名；经 Tailscale，本机 tailnet IP 【内网地址】）。
- Debian 12，用户 `ops`，免密 sudo；工作区 `~/ai-repair/`
- 接入细节与排雷记录：`06-会议记录/构建机接入记录_构建机_20260912.md`
- p1（【内网地址】）**不能**直连 163；243（te-prod-app-01, 【内网地址】, 用户 kt）是凭证跳板

## 代码架构（三个层次）

```
05-tools/
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

## 构建实战排雷（2026-09-12 首版 ISO 四轮失败教训）

- **镜像源**：构建机在国内，deb.debian.org 慢到不可用；auto/config 已锁阿里云镜像（~9MB/s）。
- **claude-code 2.x 是原生二进制**：npm 包里 `bin/claude.exe` 是 Bun 编译的 Linux ELF（~235MB），**不能用 node 加载**（报 ERR_UNKNOWN_FILE_EXTENSION）；主包 tarball 里的 claude.exe 只是 500B 占位符，真实二进制在平台包 `@anthropic-ai/claude-code-linux-x64`，由 postinstall 复制。build.sh 用 npm install（postinstall 自动拼装）；update-claude.sh 无 npm 时手动下平台包拼装 + 体积校验（>10MB）防占位符混入。
- **live 用户时序**：live 用户由 live-config 在**首次开机**创建，构建期 chroot 内不存在——hook 里不能对它 passwd/useradd（用 `id` 幂等防护）。
- **lb 脏状态**：build.sh 不做 `lb clean`，跨轮构建的 `.build/` 标记可能与 chroot 实际内容不一致（标记说内核已装、实际 /boot 空）。改 hooks/package-lists 后重构建，先 `sudo rm -rf .build chroot binary*`（保留 cache/ 组件缓存）再跑 build.sh。
- **远端构建用 nohup 脱离 ssh**：`ssh 构建机 'sudo sh -c "cd ~/ai-repair/live-build-config && nohup bash build.sh > /tmp/iso-build.log 2>&1 &"'`，本地中断/内存清理杀不掉；日志看 `/tmp/iso-build.log`。
- **bookworm 固件包名**：`firmware-mediatek` 是 trixie 才有的包，bookworm 用 `firmware-misc-nonfree`。

## git 推送

remote URL 不含凭证。推送用一次性 PAT URL（用完即弃，不写入 remote）：
`git push https://zangxin75:<PAT>@github.com/zangxin75/ai-repair-usb.git main:main`

## 文档规范（用户全局 CLAUDE.md 强制）

- 新文档按类型入 `01-planning/ … 06-会议记录/`，命名 `[类型]_[项目名]_[日期].md`，不得放根目录
- 每篇文档含：创建日期 / 版本 / 状态 / 作者
- 关键交付物同步更新 `01-planning/README.md` 进度

## 审计工作流

设计/计划类文档落地前须过 critic 审计循环（本仓历史：设计 3 轮 6.0→8.5，计划 3 轮→8.5 ACCEPT）；代码交付须 verifier 独立复验（首轮 FAIL 修复后 PASS，冒烟 15/15）。
