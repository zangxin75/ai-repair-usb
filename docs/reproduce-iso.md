# 从零复现维修系统 ISO（陌生人视角）

目标：在一台 Debian 12 实体机/VM 上，从源码构建出与官方 Release 等价的 `AI-Repair-Live-*.iso`。WSL2 不行（缺 loop 设备）。

## 0. 准备

- Debian 12 x86_64 主机，≥40GB 空闲盘，能访问 Debian 镜像源
- clone 本仓

```bash
git clone https://github.com/zangxin75/ai-repair-usb.git && cd ai-repair-usb
```

## 1. 构建机依赖

```bash
sudo bash setup-build-host.sh
```

装的是 live-build、内核与固件包、squashfs-tools、xorriso 等构建依赖（幂等，可重复执行）。

## 2. 构建

```bash
cd 05-执行工具/live-build-config
sudo bash build.sh            # 首次 ~30-60 分钟（取决于网络）
```

改过 `hooks/` / `package-lists/` 后重构建，先清理脏状态（保留缓存）：

```bash
sudo rm -rf .build chroot binary*
sudo bash build.sh
```

产物在 `images/`（或构建输出目录），附 `.sha256`。

## 3. 验证

```bash
sha256sum -c *.sha256
# 关键内容抽查（内核 / squashfs / claude-code 二进制在盘）
```

## 4. 常见坑（实战排雷记录）

| 坑 | 解法 |
|---|---|
| 国内拉 deb.debian.org 极慢 | `auto/config` 已锁国内镜像，别改回官方源 |
| claude-code 2.x 是原生 ELF（Bun 编译 ~235MB），npm 主包里只有 500B 占位符 | `build.sh` 用 `npm install` 让 postinstall 自动拼装平台包 `@anthropic-ai/claude-code-linux-x64`；手动路径见 `update-claude.sh`（>10MB 体积校验防占位符） |
| live 用户首次开机才由 live-config 创建 | hook 里不要 passwd/useradd（已做 `id` 幂等防护） |
| bookworm 没有 `firmware-mediatek` | 用 `firmware-misc-nonfree` |

## 5. 不构建 ISO，只想试脚本？

```bash
cd 05-执行工具 && bash tests/smoke.sh   # 15 项断言，全 mock，CI 同款
```
