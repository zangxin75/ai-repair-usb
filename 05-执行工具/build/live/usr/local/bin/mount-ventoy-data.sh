#!/usr/bin/env bash
# mount-ventoy-data.sh —— 挂载 Ventoy exFAT 数据分区到 /mnt/ventoy（幂等）
#
# 用途：按卷标 Ventoy 查找 exFAT 数据分区并挂载到 /mnt/ventoy；
#       已挂载则直接返回成功（幂等）；找不到时列出全部块设备让用户 whiptail 手选。
#
# 调用方：welcome.sh（第1步）、install-windows.sh、backup-user-data.sh、update-claude.sh
# 依赖命令：blkid lsblk mount whiptail
# 退出码：0=已挂载；1=失败/用户取消
set -euo pipefail

# 挂载需要 root：普通用户调用时自动经 sudo 重新执行自身（live 用户已配置免密 sudo）
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

MNT="/mnt/ventoy"

show_help() {
    cat <<'EOF'
用法: mount-ventoy-data.sh
按卷标 Ventoy 查找 exFAT 数据分区并挂载到 /mnt/ventoy（已挂载则直接成功）。
找不到时列出所有块设备让用户手动选择。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

# 幂等：已挂载直接成功
if mountpoint -q "$MNT" 2>/dev/null; then
    echo "    数据分区已挂载在 $MNT。"
    exit 0
fi

mkdir -p "$MNT"

# 按卷标 Ventoy 查找（exFAT 优先）
DEV=$(blkid -L Ventoy 2>/dev/null || true)

do_mount() {
    local dev="$1"
    mount -t exfat -o rw,uid=1000,gid=1000,umask=022 "$dev" "$MNT" 2>/dev/null \
        || mount -o rw "$dev" "$MNT" 2>/dev/null
}

if [[ -n "$DEV" ]] && do_mount "$DEV"; then
    echo "    已挂载 $DEV（卷标 Ventoy）到 $MNT。"
    exit 0
fi

# 自动查找失败 → 列出所有块设备让用户手选
echo "    未自动找到卷标为 Ventoy 的分区，请手动选择。" >&2
mapfile -t LINES < <(lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL -n -p 2>/dev/null \
    | awk '$1 ~ /^\/dev\// {print}')
[[ ${#LINES[@]} -gt 0 ]] || { echo "    错误：未检测到任何块设备。" >&2; exit 1; }

ITEMS=()
i=1
while IFS= read -r line; do
    ITEMS+=("$i" "$line")
    i=$((i+1))
done <<< "$(printf '%s\n' "${LINES[@]}")"

CHOICE=$(whiptail --title "手动选择数据分区" --menu \
    "未自动找到 U盘 数据分区，请从列表中选择\n（一般是容量最大、类型 exfat 的那个）：" \
    20 78 12 "${ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1

SEL="${LINES[$((CHOICE-1))]}"
SEL_DEV=$(echo "$SEL" | awk '{print $1}')

if do_mount "$SEL_DEV"; then
    echo "    已挂载 $SEL_DEV 到 $MNT。"
    exit 0
else
    echo "    挂载 $SEL_DEV 失败。" >&2
    whiptail --title "挂载失败" --msgbox \
        "挂载 $SEL_DEV 失败。\n可能是分区损坏，可尝试修复：sudo fsck.exfat $SEL_DEV" 10 60
    exit 1
fi
