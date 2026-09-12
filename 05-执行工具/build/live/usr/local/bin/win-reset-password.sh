#!/usr/bin/env bash
# win-reset-password.sh —— Windows 本机账户密码重置
#
# 用途：枚举 NTFS 分区找 Windows 安装（Windows/System32/config/SAM 存在性）→
#       chntpw -l 列出用户 → whiptail 编号选账户 → 确认后 chntpw 清除密码 → 中文结果提示。
#
# 调用方：main-menu.sh 密码重置流程（由 Claude 调用）、用户手动
# 依赖命令：lsblk ntfs-3g chntpw whiptail
# 说明：只支持本机账户；微软邮箱账户需走官网找回（脚本会提示）。
#       BitLocker 加密分区需先用 bitlocker-unlock.sh 解锁。
set -euo pipefail

show_help() {
    cat <<'EOF'
用法: sudo win-reset-password.sh
自动查找 Windows 安装分区，列出本机账户，编号选择后清除其登录密码。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

MNT="/mnt/winreset_$$"
cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

# 枚举 NTFS 分区
mapfile -t NTFS_PARTS < <(lsblk -n -o NAME,FSTYPE -p -r 2>/dev/null \
    | awk '$2=="ntfs" {print $1}' || true)
[[ ${#NTFS_PARTS[@]} -gt 0 ]] || {
    echo "未检测到 Windows 分区（NTFS 格式）。" >&2
    echo "提示：若分区被 BitLocker 加密，请先运行 bitlocker-unlock.sh 解锁。" >&2
    exit 1
}

# 找含 Windows 安装的分区
mkdir -p "$MNT"
WIN_PART=""
SAM_PATH=""
for p in "${NTFS_PARTS[@]}"; do
    if ntfs-3g -o ro "$p" "$MNT" 2>/dev/null || mount -o ro -t ntfs-3g "$p" "$MNT" 2>/dev/null; then
        for base in "$MNT/Windows/System32/config" "$MNT/WINDOWS/System32/config"; do
            if [[ -f "$base/SAM" ]]; then
                WIN_PART="$p"; SAM_PATH="$base/SAM"; break 2
            fi
        done
        umount "$MNT" 2>/dev/null || true
    fi
done

if [[ -z "$WIN_PART" ]]; then
    echo "在全部 NTFS 分区中都没找到 Windows 系统（缺少存密码的系统文件）。" >&2
    echo "可能原因：① 系统盘被 BitLocker 加密 → 先运行 bitlocker-unlock.sh" >&2
    echo "          ② Windows 未正常关机导致分区锁定 → 先执行 sudo ntfsfix <分区>" >&2
    exit 1
fi

echo "找到 Windows 系统分区：$WIN_PART"

# 读写挂载（密码重置需要写入）
if ! ntfs-3g -o remove_hiberfile "$WIN_PART" "$MNT" 2>/dev/null; then
    if ! ntfs-3g -o ro "$WIN_PART" "$MNT" 2>/dev/null; then
        echo "挂载失败。" >&2
        whiptail --title "挂载失败" --msgbox \
            "无法挂载 Windows 分区。\n常见原因：Windows 未正常关机（快速启动/休眠锁定）。\n可先执行：sudo ntfsfix $WIN_PART\n然后重试。" 12 64
        exit 1
    fi
    echo "警告：分区以只读方式挂载，无法修改密码。" >&2
    echo "可先执行：sudo ntfsfix $WIN_PART 然后重试。" >&2
    exit 1
fi

SAM_PATH="$MNT/Windows/System32/config/SAM"
[[ -f "$SAM_PATH" ]] || SAM_PATH="$MNT/WINDOWS/System32/config/SAM"

# 列出用户
USER_LIST=$(chntpw -l "$SAM_PATH" 2>/dev/null || true)
echo "$USER_LIST"
[[ -n "$USER_LIST" ]] || { echo "读取账户列表失败。" >&2; exit 1; }

# 解析用户名（chntpw -l 输出: "RID | Username |" 形式，具体格式按版本兼容处理）
mapfile -t USERS < <(echo "$USER_LIST" | awk -F'|' '/\|.*\|/ {
    u=$2; gsub(/^[ \t]+|[ \t]+$/, "", u);
    if (u != "" && u != "Username") print u
}' | sort -u)

if [[ ${#USERS[@]} -eq 0 ]]; then
    echo "未能解析出账户列表，请把上面的输出截图给维修人员。" >&2
    exit 1
fi

ITEMS=()
i=1
for u in "${USERS[@]}"; do ITEMS+=("$i" "$u"); i=$((i+1)); done
CH=$(whiptail --title "选择账户" --menu \
    "检测到以下本机账户，选择要清除密码的账户：\n（若开机时用微软邮箱登录，本操作无效，\n请到微软官网找回密码）" \
    20 64 12 "${ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1
TARGET="${USERS[$((CH-1))]}"

whiptail --title "确认清除密码" --yesno \
"将对账户「$TARGET」做以下操作：

清除它的登录密码（下次开机不用输密码直接进系统）。

影响：该账户用旧密码加密保存的网页密码等数据将失效。
此操作只影响本机登录，不影响文件内容。

确认执行？" 16 62 || { echo "用户已取消。"; exit 0; }

# 清除密码：chntpw 交互模式下选项 1
if printf '1\nq\ny\n' | chntpw -u "$TARGET" "$SAM_PATH" >/dev/null 2>&1; then
    whiptail --title "完成" --msgbox \
        "账户「$TARGET」的密码已清除。\n重启后该账户不用输密码即可登录。\n建议进系统后重新设置一个密码。" 12 60
    echo "完成：账户 $TARGET 密码已清除。"
    exit 0
else
    whiptail --title "操作未成功" --msgbox \
        "密码清除未成功。常见原因：\n1. 分区被加密（先运行 bitlocker-unlock.sh）\n2. Windows 未正常关机（先 sudo ntfsfix $WIN_PART）\n3. 该账户是微软在线账户（需官网找回）" 14 62
    exit 1
fi
