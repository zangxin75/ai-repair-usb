#!/usr/bin/env bash
# offline-menu.sh —— 离线降级菜单（无网/AI 网关不通时）
#
# 用途：网络不可用时的 whiptail 本地工具菜单：
#       硬件检测/磁盘体检/数据备份/密码重置（均不依赖 AI）+ 重新检测网络。
#
# 调用方：welcome.sh（网络诊断失败且用户选择离线模式）、main-menu.sh --offline
# 依赖命令：whiptail check-network.sh main-menu.sh disk-check.sh backup-user-data.sh
#           win-reset-password.sh lshw sensors
set -euo pipefail

show_help() {
    cat <<'EOF'
用法: offline-menu.sh
无网/网关不通时的本地工具菜单。全部功能不依赖 AI 联网。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

while true; do
    CHOICE=$(whiptail --title "离线模式 · 本地维修工具" --menu \
"当前无网络或 AI 服务不可用，AI 对话功能暂停。
以下本地工具不受影响，可正常使用：" 18 64 6 \
        "1" "硬件检测（查看 CPU/内存/显卡等硬件型号与温度）" \
        "2" "磁盘体检（硬盘自检报告 + 坏道只读扫描）" \
        "3" "数据备份（抢救文件到 U盘/外接盘）" \
        "4" "密码重置（清除 Windows 本机账户密码）" \
        "5" "重新检测网络（恢复 AI 功能）" \
        "6" "退出到命令行" \
        3>&1 1>&2 2>&3) || exit 0

    case "$CHOICE" in
        1)
            echo "════════ 硬件清单 ════════"
            sudo lshw -short 2>/dev/null || lshw -short 2>/dev/null || true
            echo
            echo "════════ 温度 ════════"
            sensors 2>/dev/null || echo "（无传感器数据，可先运行 sudo sensors-detect --auto）"
            echo
            read -rp "按回车返回菜单…" || true
            ;;
        2)
            sudo disk-check.sh || disk-check.sh || true
            read -rp "按回车返回菜单…" || true
            ;;
        3)
            sudo backup-user-data.sh || backup-user-data.sh || true
            read -rp "按回车返回菜单…" || true
            ;;
        4)
            sudo win-reset-password.sh || win-reset-password.sh || true
            read -rp "按回车返回菜单…" || true
            ;;
        5)
            if check-network.sh; then
                whiptail --title "网络恢复" --msgbox \
                    "网络与 AI 网关已连通，即将进入完整功能主菜单。" 10 56
                exec main-menu.sh
            else
                whiptail --title "仍未连通" --msgbox \
                    "网络仍未恢复，继续留在离线模式。\n可检查网线/WiFi 后再试。" 10 56
            fi
            ;;
        6)
            echo "已退出菜单。手动使用工具：ls /usr/local/bin/*.sh，各脚本带 --help 查看用法。"
            exit 0
            ;;
    esac
done
