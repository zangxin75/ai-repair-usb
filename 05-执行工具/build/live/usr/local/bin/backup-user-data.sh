#!/usr/bin/env bash
# backup-user-data.sh —— 用户数据备份向导
#
# 用途：whiptail 选源盘（NTFS 分区，列出 Users 目录大小）→
#       选目标（/mnt/ventoy 或外接盘，检查剩余空间）→
#       rsync -avP 带进度备份 Users 目录 → 完成报告（文件数/大小/跳过项）。
#
# 调用方：main-menu.sh 备份流程（由 Claude 调用）、用户手动
# 依赖命令：lsblk ntfs-3g du rsync whiptail df
set -euo pipefail

show_help() {
    cat <<'EOF'
用法: sudo backup-user-data.sh
备份 Windows 分区的 Users 目录（桌面/文档等）到 U盘 或外接盘。
向导式：选源分区 → 选目标 → 带进度备份 → 完成报告。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

SRC_MNT="/mnt/backup_src_$$"
DST_MNT="/mnt/backup_dst_$$"
cleanup() {
    umount "$SRC_MNT" 2>/dev/null || true; rmdir "$SRC_MNT" 2>/dev/null || true
    umount "$DST_MNT" 2>/dev/null || true; rmdir "$DST_MNT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- 选源盘 ----------
mapfile -t NTFS_PARTS < <(lsblk -n -o NAME,FSTYPE -p -r 2>/dev/null \
    | awk '$2=="ntfs" {print $1}' || true)
[[ ${#NTFS_PARTS[@]} -gt 0 ]] || {
    echo "未检测到 Windows 分区。" >&2
    echo "提示：若分区被 BitLocker 加密，请先运行 bitlocker-unlock.sh。" >&2
    exit 1
}

mkdir -p "$SRC_MNT"
ITEMS=(); i=1
declare -A SRC_MAP=()
for p in "${NTFS_PARTS[@]}"; do
    USERS_SIZE="无用户目录"
    if ntfs-3g -o ro "$p" "$SRC_MNT" 2>/dev/null; then
        for ud in "$SRC_MNT/Users" "$SRC_MNT/Documents and Settings"; do
            if [[ -d "$ud" ]]; then
                USERS_SIZE=$(du -sh "$ud" 2>/dev/null | awk '{print $1}')
                USERS_SIZE="用户文件约 $USERS_SIZE"
                break
            fi
        done
        umount "$SRC_MNT" 2>/dev/null || true
    fi
    SZ=$(lsblk -n -b -o SIZE "$p" 2>/dev/null | head -1)
    ITEMS+=("$i" "$p（约 $((SZ/1024/1024/1024))GB，$USERS_SIZE）")
    SRC_MAP[$i]="$p"
    i=$((i+1))
done
CH=$(whiptail --title "选择要备份的分区" --menu \
    "从哪里抢救文件？选择存放用户文件的分区：\n（一般选「用户文件」不为空的那个）" \
    18 70 10 "${ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1
SRC_PART="${SRC_MAP[$CH]}"

ntfs-3g -o ro "$SRC_PART" "$SRC_MNT" 2>/dev/null \
    || mount -o ro -t ntfs-3g "$SRC_PART" "$SRC_MNT"
SRC_DIR=""
for ud in "$SRC_MNT/Users" "$SRC_MNT/Documents and Settings"; do
    [[ -d "$ud" ]] && SRC_DIR="$ud" && break
done
[[ -n "$SRC_DIR" ]] || { echo "该分区没有找到用户目录。" >&2; exit 1; }

# ---------- 选目标 ----------
ITEMS=()
if mountpoint -q /mnt/ventoy 2>/dev/null; then
    FREE=$(df -h /mnt/ventoy | awk 'NR==2{print $4}')
    ITEMS+=("1" "U盘 数据分区（剩余 $FREE，推荐——文件跟工具盘在一起）")
fi
# 外接盘（usb 但非 U盘 自身分区：挂到临时点列一下）
j=2
declare -A DST_MAP=()
while read -r dev fstype; do
    case "$fstype" in ntfs|exfat|vfat|ext4)
        # 排除已作为 /mnt/ventoy 的分区
        cur=$(findmnt -n -o SOURCE /mnt/ventoy 2>/dev/null || true)
        [[ "$dev" == "$cur" ]] && continue
        mkdir -p "$DST_MNT"
        if mount -o rw "$dev" "$DST_MNT" 2>/dev/null \
           || { [[ "$fstype" == "ntfs" ]] && ntfs-3g "$dev" "$DST_MNT" 2>/dev/null; }; then
            FREE=$(df -h "$DST_MNT" | awk 'NR==2{print $4}')
            ITEMS+=("$j" "外接盘 $dev（剩余 $FREE）")
            DST_MAP[$j]="$DST_MNT"
            j=$((j+1))
        fi ;;
    esac
done < <(lsblk -n -o NAME,FSTYPE,MOUNTPOINT -p -r 2>/dev/null \
    | awk '$2!="" && $3=="" {print $1, $2}' \
    | grep -v -E '^/dev/(loop|ram|sr)' || true)

[[ ${#ITEMS[@]} -gt 0 ]] || { echo "没有可用的备份目标（U盘未挂载且无其他外接盘）。" >&2; exit 1; }
CH=$(whiptail --title "选择备份到哪" --menu \
    "把文件备份到哪里？" 16 66 8 "${ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1
if [[ "$CH" == "1" ]] && mountpoint -q /mnt/ventoy 2>/dev/null; then
    DST_BASE="/mnt/ventoy"
else
    DST_BASE="${DST_MAP[$CH]}"
fi

DEST="$DST_BASE/备份_$(date +%Y%m%d_%H%M)"
mkdir -p "$DEST"

# ---------- 空间检查 ----------
NEED_KB=$(du -sk "$SRC_DIR" 2>/dev/null | awk '{print $1}')
FREE_KB=$(df -k "$DST_BASE" | awk 'NR==2{print $4}')
if (( NEED_KB > FREE_KB )); then
    whiptail --title "空间不足" --yesno \
"目标位置剩余空间不足：
需要约 $((NEED_KB/1024/1024)) GB，只剩约 $((FREE_KB/1024/1024)) GB。

可选：只备份最常用的「桌面」和「文档」目录？
（选 No 则取消备份）" 14 62 || exit 1
    SRC_LIST=("$SRC_DIR"/*/Desktop "$SRC_DIR"/*/Documents)
    RSYNC_SRC=()
    for d in "${SRC_LIST[@]}"; do [[ -d "$d" ]] && RSYNC_SRC+=("$d"); done
else
    RSYNC_SRC=("$SRC_DIR")
fi

# ---------- 备份 ----------
LOG=/tmp/backup_$$.log
echo "开始备份到 $DEST（带进度，请勿拔盘）…"
set +e
rsync -avP --no-perms --chmod=ugo=rwX "${RSYNC_SRC[@]}" "$DEST/" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e

# ---------- 完成报告 ----------
FILES=$(find "$DEST" -type f 2>/dev/null | wc -l)
TOTAL=$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')
SKIPPED=$(grep -c -E 'Permission denied|vanished|error' "$LOG" 2>/dev/null || echo 0)

if [[ $RC -eq 0 || $RC -eq 23 || $RC -eq 24 ]]; then
    whiptail --title "备份完成" --msgbox \
"备份完成！
位置：$DEST
文件数：$FILES 个    总大小：$TOTAL
跳过/无法读取：$SKIPPED 项

提醒：拔盘前请确认完成；重要文件建议打开几个核对。" 14 64
    exit 0
else
    whiptail --title "备份中断" --msgbox \
        "备份过程出错（rsync 退出码 $RC）。\n已备份的部分在 $DEST，可重试续传。" 10 60
    exit 1
fi
