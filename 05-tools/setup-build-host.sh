#!/usr/bin/env bash
# setup-build-host.sh — AI 电脑维修 U盘 · Debian 构建机环境准备（P0）
# 用途：在 Debian 12 (bookworm) 构建机上一键安装 live-build 及全部构建依赖
# 用法：sudo bash setup-build-host.sh
set -euo pipefail

echo "=== AI 电脑维修 U盘 · 构建机环境准备 ==="

if [[ $EUID -ne 0 ]]; then
  echo "错误：请以 root 运行（sudo bash $0）" >&2
  exit 1
fi

if ! grep -qiE 'debian|ubuntu' /etc/os-release; then
  echo "错误：本脚本面向 Debian 12 / Ubuntu 系构建机" >&2
  exit 1
fi

echo "[1/3] 更新软件源..."
apt-get update -qq

echo "[2/3] 安装构建依赖（live-build + 镜像工具链 + 实用工具）..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  live-build \
  debootstrap \
  squashfs-tools \
  xorriso \
  isolinux \
  syslinux-common \
  syslinux-efi \
  grub-pc-bin \
  grub-efi-amd64-bin \
  mtools \
  dosfstools \
  exfatprogs \
  parted \
  git \
  curl \
  wget \
  jq \
  ca-certificates \
  shellcheck \
  p7zip-full \
  wimtools

echo "[3/3] 验证关键命令..."
missing=0
for cmd in lb debootstrap mksquashfs xorriso git curl jq shellcheck wimlib-imagex mkfs.exfat; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ✓ %s\n" "$cmd"
  else
    printf "  ✗ %s （缺失）\n" "$cmd"
    missing=1
  fi
done

if [[ $missing -ne 0 ]]; then
  echo "错误：存在缺失命令，请检查上方输出" >&2
  exit 1
fi

echo
echo "=== 构建机就绪 ==="
echo "下一步：cd 05-tools/live-build-config && sudo bash build.sh"
echo "注意：WSL2 不适合跑 lb build（缺 loop 设备支持），请在实体机/完整虚拟机中构建。"
