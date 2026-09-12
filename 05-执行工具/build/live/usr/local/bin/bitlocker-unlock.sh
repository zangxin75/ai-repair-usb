#!/usr/bin/env bash
# bitlocker-unlock.sh —— BitLocker 加密分区检测与解锁向导
#
# 用途：枚举 BitLocker 加密分区 → whiptail 输入 48 位恢复密钥 →
#       dislocker 解锁 → ntfs-3g 挂载 → 输出挂载点。
#
# 调用方：Claude Code（密码重置/数据备份/重装前的解锁分支）、用户手动
# 依赖命令：lsblk dislocker ntfs-3g whiptail
# 说明：仅在用户提供恢复密钥后解锁，不绕过加密（设计 §2.4-3）。
set -euo pipefail

show_help() {
    cat <<'EOF'
用法: sudo bitlocker-unlock.sh
检测 BitLocker 加密分区，引导输入恢复密钥，解锁并挂载，输出挂载点路径。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

# 枚举 BitLocker 分区
mapfile -t BL_PARTS < <(lsblk -n -o NAME,FSTYPE -p -r 2>/dev/null \
    | awk '$2 ~ /[Bb]it[Ll]ocker/ {print $1}' || true)

if [[ ${#BL_PARTS[@]} -eq 0 ]]; then
    echo "未检测到 BitLocker 加密分区。"
    exit 1
fi

# 有多个时让用户选
if [[ ${#BL_PARTS[@]} -eq 1 ]]; then
    PART="${BL_PARTS[0]}"
else
    ITEMS=()
    i=1
    for p in "${BL_PARTS[@]}"; do
        SZ=$(lsblk -n -b -o SIZE "$p" 2>/dev/null | head -1)
        ITEMS+=("$i" "$p（约 $(( SZ/1024/1024/1024 )) GB）")
        i=$((i+1))
    done
    CH=$(whiptail --title "选择加密分区" --menu \
        "检测到多个 BitLocker 加密分区，请选择要解锁的：" 16 60 8 \
        "${ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1
    PART="${BL_PARTS[$((CH-1))]}"
fi

echo "目标加密分区：$PART"
whiptail --title "BitLocker 解锁" --msgbox \
"该分区被 BitLocker 加密（Windows 的设备加密功能）。
需要 48 位恢复密钥才能解锁（本工具不绕过加密）。

获取方法：用能上网的设备登录
  account.microsoft.com/devices/recoverykey
用机主的微软账户登录后可以看到恢复密钥。" 16 64

KEY=$(whiptail --title "输入恢复密钥" --inputbox \
    "请输入 48 位恢复密钥（形如 123456-123456-……）：" 10 64 3>&1 1>&2 2>&3) || exit 1
KEY=$(echo "$KEY" | tr -d '[:space:]')
[[ "$KEY" =~ ^([0-9]{6}-){7}[0-9]{6}$ || "$KEY" =~ ^[0-9]{48}$ ]] || {
    whiptail --title "格式不对" --msgbox \
        "恢复密钥应为 48 位数字（可带连字符）。\n请核对后重试。" 10 56
    exit 1
}

DISLOCKER_DIR="/mnt/dislocker_$(basename "$PART")"
TARGET_DIR="/mnt/windows_$(basename "$PART")"
mkdir -p "$DISLOCKER_DIR" "$TARGET_DIR"

echo "正在解锁（dislocker）…"
if ! dislocker -r -V "$PART" -r --recovery-password="$KEY" -- "$DISLOCKER_DIR" 2>/dev/null \
   && ! dislocker -V "$PART" --recovery-password="$KEY" -- "$DISLOCKER_DIR" 2>/dev/null; then
    rmdir "$DISLOCKER_DIR" "$TARGET_DIR" 2>/dev/null || true
    echo "解锁失败。" >&2
    whiptail --title "解锁失败" --msgbox \
"恢复密钥无法解锁该分区，请排查：
1. 密钥是否输错（注意区分 0/O、1/I）——建议重试一次
2. 密钥是否对应这台电脑的这个分区（微软账户里可能有多台设备）
3. 该分区可能用的是开机密码而非恢复密钥加密——需原密码
4. 分区损坏——可先用磁盘体检（disk-check.sh）排查硬盘问题" 16 64
    exit 1
fi

echo "解锁成功，正在挂载文件系统…"
if ntfs-3g -o ro "$DISLOCKER_DIR/dislocker-file" "$TARGET_DIR" 2>/dev/null \
   || ntfs-3g -o remove_hiberfile "$DISLOCKER_DIR/dislocker-file" "$TARGET_DIR" 2>/dev/null; then
    echo "已挂载到：$TARGET_DIR"
    whiptail --title "解锁成功" --msgbox \
        "加密分区已解锁并挂载到：\n  $TARGET_DIR\n\n现在可以读取/备份里面的文件了。\n（用完可执行 umount $TARGET_DIR 卸载）" 12 64
    echo "$TARGET_DIR"
    exit 0
else
    echo "挂载失败（可能是 Windows 未正常关机导致锁定）。" >&2
    whiptail --title "挂载失败" --msgbox \
        "已解锁但挂载失败，常见原因是 Windows 没有正常关机。\n可先执行修复后再试：\n  sudo ntfsfix $DISLOCKER_DIR/dislocker-file" 12 64
    exit 1
fi
