#!/usr/bin/env bash
# disk-check.sh —— 硬盘体检：SMART 摘要 + 只读坏道扫描，输出中文三级体检报告
#
# 用途：枚举全部物理盘（用 /dev/disk/by-id/ 的 usb- 前缀排除 U盘 自身），
#       对每块盘输出 smartctl -a 摘要、可选只读坏道扫描（badblocks 只读模式），
#       汇总为「健康/警告/危险」三级结论先行的中文报告（细节可折叠查看）。
#
# 调用方：main-menu.sh 体检/硬件检测流程（由 Claude 调用）、用户手动
# 依赖命令：smartctl lsblk badblocks whiptail
# 说明：全程只读，不写入被检测盘。
set -euo pipefail

show_help() {
    cat <<'EOF'
用法: sudo disk-check.sh [--no-badblocks]
枚举物理盘（自动排除 U盘 自身），输出 SMART 健康摘要与中文三级体检报告。
--no-badblocks  跳过只读坏道扫描（只出 SMART 报告，速度快）
EOF
}
DO_BADBLOCKS=1
for arg in "$@"; do
    case "$arg" in
        --no-badblocks) DO_BADBLOCKS=0 ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "未知参数: $arg" >&2; exit 64 ;;
    esac
done

# 判断一块盘是否为 U盘（安装介质自身）：by-id 路径含 usb- 前缀
is_usb_disk() {
    local dev="$1" link
    for link in /dev/disk/by-id/*; do
        [[ -e "$link" ]] || continue
        case "$(basename "$link")" in
            usb-*)
                [[ "$(readlink -f "$link")" == "$dev" ]] && return 0 ;;
        esac
    done
    return 1
}

# 枚举物理盘（排除 loop/rom 与 U盘 自身）
mapfile -t ALL_DISKS < <(lsblk -d -n -o NAME,TYPE 2>/dev/null \
    | awk '$2=="disk" {print "/dev/"$1}' | grep -v -E '^/dev/(loop|ram|sr)' || true)

DISKS=()
for d in "${ALL_DISKS[@]:-}"; do
    [[ -n "$d" ]] || continue
    is_usb_disk "$d" && { echo "    已排除 U盘 自身：$d"; continue; }
    DISKS+=("$d")
done

[[ ${#DISKS[@]} -gt 0 ]] || { echo "未检测到可检测的内置硬盘。" >&2; exit 1; }

# 坏道扫描需逐盘耗时，先让用户确认范围
if [[ $DO_BADBLOCKS -eq 1 ]] && command -v whiptail >/dev/null 2>&1; then
    whiptail --title "硬盘体检" --yesno \
"即将进行两项检查：
1. 读取硬盘自检报告（SMART），很快
2. 只读坏道扫描（逐扇区读一遍，每块盘可能要几十分钟，全程不写入任何数据）

是否进行坏道扫描？
（选 No 则只做快速的 SMART 检查）" 14 64 && DO_BADBLOCKS=1 || DO_BADBLOCKS=0
fi

REPORT=""
DISK_COUNT=0
WARN_COUNT=0
CRIT_COUNT=0

for DEV in "${DISKS[@]}"; do
    DISK_COUNT=$((DISK_COUNT+1))
    MODEL=$(lsblk -d -n -o MODEL "$DEV" 2>/dev/null | head -1 | xargs || echo "未知型号")
    SIZE=$(lsblk -d -n -b -o SIZE "$DEV" 2>/dev/null | head -1 | xargs || echo 0)
    SIZE_GB=$(( SIZE / 1024 / 1024 / 1024 ))

    echo
    echo "════════ 硬盘 $DISK_COUNT：$DEV ════════"
    echo "型号：${MODEL:-未知}    容量：约 ${SIZE_GB} GB"

    SMART_OUT=$(smartctl -a "$DEV" 2>/dev/null || true)

    # ---- 结论判定 ----
    LEVEL="健康"
    REASONS=()
    if [[ -z "$SMART_OUT" ]]; then
        LEVEL="警告"; REASONS+=("读不到自检报告（可能是老硬盘或接口卡转接）")
    else
        if echo "$SMART_OUT" | grep -q "PASSED"; then :;
        elif echo "$SMART_OUT" | grep -q "FAILED"; then
            LEVEL="危险"; REASONS+=("硬盘自检报告明确判为不合格（FAILED）")
        else
            REASONS+=("自检报告无明确结论")
        fi
        REALLOC=$(echo "$SMART_OUT" | awk '/Reallocated_Sector/ {print $NF}' | head -1 || echo 0)
        PENDING=$(echo "$SMART_OUT" | awk '/Current_Pending_Sector/ {print $NF}' | head -1 || echo 0)
        UDME=$(echo "$SMART_OUT" | awk '/UDMA_CRC_Error_Count/ {print $NF}' | head -1 || echo 0)
        [[ "${REALLOC:-0}" =~ ^[0-9]+$ ]] || REALLOC=0
        [[ "${PENDING:-0}" =~ ^[0-9]+$ ]] || PENDING=0
        [[ "${UDME:-0}" =~ ^[0-9]+$ ]] || UDME=0
        if (( PENDING > 0 || REALLOC > 50 )); then
            LEVEL="危险"; REASONS+=("出现待处理坏扇区 ${PENDING} 个 / 已重映射坏扇区 ${REALLOC} 个，硬盘正在损坏")
        elif (( REALLOC > 0 )); then
            [[ "$LEVEL" == "健康" ]] && LEVEL="警告"
            REASONS+=("已有 ${REALLOC} 个坏扇区被自动修复，建议备份并密切观察")
        fi
        if (( UDME > 0 )); then
            [[ "$LEVEL" == "健康" ]] && LEVEL="警告"
            REASONS+=("数据线传输出过错（${UDME} 次），多半是数据线/接口松动，换线试试")
        fi
        TEMP=$(echo "$SMART_OUT" | awk '/Temperature_Celsius|Temperature_Internal/ {print $10}' | head -1 || true)
        if [[ "${TEMP:-0}" =~ ^[0-9]+$ ]] && (( TEMP >= 55 )); then
            [[ "$LEVEL" == "健康" ]] && LEVEL="警告"
            REASONS+=("硬盘温度偏高（${TEMP}℃），注意散热")
        fi
    fi

    # ---- 坏道只读扫描 ----
    BB_RESULT="未扫描"
    if [[ $DO_BADBLOCKS -eq 1 ]]; then
        echo "正在进行只读坏道扫描（不会写入任何数据，时间较长）…"
        echo "（下方显示实时进度百分比；跳过可按 Ctrl+C）"
        # 保留百分比进度行输出（§2.6.2-4：长任务进度可见，不让用户面对静止屏幕）
        badblocks -sv -b 4096 "$DEV" 2>&1 | tee /tmp/badblocks_$$.log \
            | grep --line-buffered -oE '[0-9]+\.[0-9]+%' || true
        BBNUM=$(grep -c -E '^[0-9]+$' /tmp/badblocks_$$.log 2>/dev/null || echo 0)
        rm -f /tmp/badblocks_$$.log
        if (( BBNUM > 0 )); then
            BB_RESULT="发现 ${BBNUM} 个坏块"
            LEVEL="危险"; REASONS+=("只读扫描发现 ${BBNUM} 个坏块，硬盘存在物理损坏")
        else
            BB_RESULT="未发现坏块"
        fi
        echo "坏道扫描结果：$BB_RESULT"
    fi

    case "$LEVEL" in
        危险) CRIT_COUNT=$((CRIT_COUNT+1));;
        警告) WARN_COUNT=$((WARN_COUNT+1));;
    esac

    # ---- 单行结论 + 折叠细节 ----
    echo "结论：【$LEVEL】"
    for r in ${REASONS[@]+"${REASONS[@]}"}; do echo "  · $r"; done
    echo "（输入 s 回车查看该盘完整自检报告，直接回车跳过）"
    read -r ANS || true
    if [[ "${ANS:-}" == "s" ]]; then
        echo "$SMART_OUT" | less
    fi

    REPORT+=$'\n'"硬盘 $DISK_COUNT（$DEV，${MODEL:-未知}，约 ${SIZE_GB}GB）：【$LEVEL】 坏道扫描：$BB_RESULT"
    for r in ${REASONS[@]+"${REASONS[@]}"}; do REPORT+=$'\n'"    · $r"; done
done

echo
echo "════════ 体检总结 ════════"
echo "$REPORT"
echo
if (( CRIT_COUNT > 0 )); then
    echo "总体结论：【危险】有硬盘存在物理损坏，请立刻备份重要文件，建议尽快更换硬盘。"
    exit 2
elif (( WARN_COUNT > 0 )); then
    echo "总体结论：【警告】有硬盘出现异常迹象，建议尽早备份重要文件并观察。"
    exit 1
else
    echo "总体结论：【健康】所有硬盘状态良好。"
    exit 0
fi
