#!/usr/bin/env bash
# AI 维修 U盘 · Linux 自动挂载安装器 v1.0.1
# v1.0.1：挂载旗标安全加固——umask 000→022（不再世界可写）+ 全分支补 nosuid,nodev（防盘上
#          setuid/设备节点在主机侧生效）；仍为 mount-only，不执行盘上任何脚本。
# 在 Linux 主机上以 root 运行一次：此后插入卷标为 Ventoy 的U盘数据分区即自动挂载到 /media/ventoy。
# 仅自动挂载，不执行盘上任何脚本。桌面版发行版本就会自动挂载，本脚本主要服务服务器 / 最小化系统。
# 用法: curl -sL https://usb.tokeneff.com/maker/install-automount.sh | sudo bash
set -euo pipefail

LABEL="Ventoy"         # Ventoy 数据分区默认卷标
MNT="/media/ventoy"    # 固定挂载点（usb-v1.0.sh 的找盘逻辑已覆盖 /media/*）
ROOT="${ROOT:-}"       # 测试钩子：ROOT=/tmp/t bash install-automount.sh 只写测试目录

[ "$(id -u)" -eq 0 ] || [ -n "$ROOT" ] || { echo "错误: 请用 root 运行（curl … | sudo bash）"; exit 1; }

install -d -m 755 "$ROOT/usr/local/sbin" "$ROOT/etc/udev/rules.d" "$ROOT/etc/systemd/system"

cat > "$ROOT/usr/local/sbin/ai-usb-automount" <<'EOF'
#!/bin/sh
# udev/systemd 回调：把卷标 Ventoy 的分区挂到 /media/ventoy；不在位或已挂载则安静退出
DEV="/dev/disk/by-label/Ventoy"
MNT="/media/ventoy"
[ -e "$DEV" ] || exit 0
mkdir -p "$MNT"
if command -v findmnt >/dev/null 2>&1 && findmnt -rn -S "$DEV" | grep -q .; then exit 0; fi
# exfat/vfat/ntfs 用 uid/gid 让桌面用户可读写；其他文件系统或拿不到用户时直接挂
U="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
if [ -n "$U" ] && id "$U" >/dev/null 2>&1; then
    mount -o "noatime,nosuid,nodev,uid=$(id -u "$U"),gid=$(id -g "$U"),umask=022" "$DEV" "$MNT" 2>/dev/null \
        || mount -o noatime,nosuid,nodev,umask=022 "$DEV" "$MNT" 2>/dev/null || true
else
    mount -o noatime,nosuid,nodev,umask=022 "$DEV" "$MNT" 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "$ROOT/usr/local/sbin/ai-usb-automount"

cat > "$ROOT/etc/udev/rules.d/99-ai-usb-automount.rules" <<EOF
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="$LABEL", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ai-usb-automount.service"
EOF

cat > "$ROOT/etc/systemd/system/ai-usb-automount.service" <<EOF
[Unit]
Description=Auto-mount AI USB data partition (label $LABEL)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ai-usb-automount
EOF

if [ -n "$ROOT" ]; then
    echo "测试模式: 规则与服务已生成在 $ROOT 下，未装载到本机。"
    exit 0
fi

udevadm control --reload-rules 2>/dev/null || true
systemctl daemon-reload
systemctl start ai-usb-automount.service
if mountpoint -q "$MNT"; then
    echo "完成: U盘已自动挂载到 $MNT"
else
    echo "完成: 以后插入U盘即自动挂载到 $MNT（盘现在插着的话，拔插一次即挂上）"
fi
echo "卸载本机制: 删除以下三个文件即可 ——"
echo "  /etc/udev/rules.d/99-ai-usb-automount.rules"
echo "  /etc/systemd/system/ai-usb-automount.service"
echo "  /usr/local/sbin/ai-usb-automount"
