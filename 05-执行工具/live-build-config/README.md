# live-build-config —— AI-Repair-Live ISO 构建配置（P2 阶段 L1-L5 交付物）

- **创建日期**: 2026-09-12
- **最后更新**: 2026-09-12
- **版本**: V0.1
- **状态**: 草稿（骨架就绪，待首次真实构建）
- **依据文档**: 《技术方案_AI电脑维修U盘_总体设计_20260912.md》V1.5 §2.2；《实施计划_AI电脑维修U盘_20260912.md》V1.4 P2

## 产物

`../dist/AI-Repair-Live-v0.1-20260912.iso` + 同名 `.sha256`（双启动 iso-hybrid，直接拷入 Ventoy 数据分区即可启动）。

## 构建方法

构建机：Debian 12 bookworm（amd64），磁盘 ≥20GB 空闲。

```bash
# 1. 安装构建依赖（实施计划 P0-D1）
sudo apt install live-build git curl jq squashfs-tools xorriso isolinux \
    syslinux-efi grub-pc-bin grub-efi-amd64-bin mtools dosfstools xz-utils

# 2. 构建（lb build 需要 root；步骤 ①-④ 下载离线组件可用普通用户先跑）
bash build.sh --deps     # 只做依赖下载/组件填充（普通用户）
sudo bash build.sh       # 完整构建 ISO
```

产物输出到 `../dist/`，升级版本号改 `build.sh` 顶部 `IMAGE_VERSION`/`IMAGE_DATE` 与 `auto/config` 的 `--image-name`（两处保持一致）。

## 目录结构

```
live-build-config/
├── build.sh                      # 构建入口：依赖检查→同步脚本→下载离线组件→lb build→产物改名+SHA256
├── auto/
│   └── config                    # lb config 参数：bookworm/amd64/xfce/syslinux+grub-efi/zh_CN.UTF-8/xz 压缩/镜像命名
├── config/
│   ├── package-lists/
│   │   └── main.list.chroot      # apt 包清单（均为 bookworm 真实包名，每包带用途注释）
│   ├── includes.chroot/          # 原样打进 ISO 根目录的文件
│   │   ├── opt/node/             # Node 20 LTS（build.sh 下载 tarball 填充）
│   │   ├── opt/claude-code/      # claude-code node_modules（build.sh 联网 npm install 填充，package-lock 锁版本）
│   │   ├── usr/local/bin/        # 维修脚本（从 ../../build/live/ 同步）
│   │   ├── usr/local/share/tasks/# 主菜单任务文本（P3.5 交付，同步机制同上）
│   │   ├── etc/skel/.claude/CLAUDE.md   # AI 维修助手系统提示词（live 用户家目录模板）
│   │   ├── etc/xdg/autostart/fcitx5.desktop  # 输入法自启动
│   │   └── etc/live/             # 自动登录占位说明（实际由 hook 0300 配 lightdm）
│   └── hooks/live/               # chroot 阶段构建钩子（编号=执行顺序）
│       ├── 0100-node-setup.hook.chroot        # Node PATH + 软链 + node --version 验证
│       ├── 0200-claude-code-setup.hook.chroot # claude 软链 + 版本验证 + 固化 /etc/ai-repair-version
│       ├── 0300-autostart.hook.chroot         # live 无密码 + lightdm autologin + 全屏终端跑 welcome.sh
│       └── 0400-locale-fonts.hook.chroot      # zh_CN.UTF-8 / Noto Sans Mono CJK / fcitx5 环境变量
├── cache/                        # 构建缓存（Node tarball、npm staging；不提交 git）
└── README.md
```

## 与 build/live 的同步关系

- **权威源**：`../build/live/`（P3/P3.5 脚本开发目录）。本仓库 `config/includes.chroot/usr/local/bin/` 与 `usr/local/share/tasks/` 只是构建期拷入点。
- **同步方式**：build.sh 第 2 步用 `cp -a` 把 `../build/live/` 顶层子树合并拷入 includes.chroot（**不是软链**，软链会把构建机绝对路径带进 ISO）。每次构建重新同步，includes.chroot 内的脚本本地改动会被覆盖。
- 首次构建预期只有 `welcome.sh` 一个脚本；welcome.sh 依赖的 check-network.sh / main-menu.sh 等由 P3 补齐后再构建完整版。

## 注意事项

- hooks 在 chroot 内执行，全部带 `set -euo pipefail`；任何一步失败构建即中止（不带病出 ISO）。
- firmware-* 包在 bookworm 位于 non-free-firmware 区，auto/config 已开 `--archive-areas "main contrib non-free non-free-firmware"`。
- live 用户免密 sudo 由 live-config 默认提供；密码清空与 lightdm autologin 由 hook 0300 完成。
- 网关环境变量不在此处配置（profile.d 时序问题，设计 §2.2.1-C）——由 welcome.sh 挂载数据分区后显式 export。
