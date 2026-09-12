#!/usr/bin/env bash
# main-menu.sh —— whiptail 中文主菜单（设计 §2.6.1 六选项）
#
# 用途：展示六项主菜单；选 1-5 时以初始 prompt 启动 claude 接管固化流程，
#       选 6 时 exec claude 自由对话。
#       --offline 离线模式：隐藏依赖 AI 的项（3/4/6 替换为本地工具入口，
#       1/2 保留但标注本地可用部分说明）。
#
# 调用方：welcome.sh（第5步）
# 依赖命令：whiptail claude
set -euo pipefail

TASKS_DIR="/usr/local/share/tasks"
OFFLINE=0
for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=1 ;;
        --help|-h)
            cat <<'EOF'
用法: main-menu.sh [--offline]
whiptail 中文主菜单，六选项；选 1-5 以任务文本启动 claude，选 6 自由对话。
--offline  离线模式：仅保留不依赖 AI 的本地工具入口。
EOF
            exit 0 ;;
        *) echo "未知参数: $arg" >&2; exit 64 ;;
    esac
done

task_prompt() { cat "$TASKS_DIR/$1"; }

if [[ $OFFLINE -eq 1 ]]; then
    exec offline-menu.sh
fi

while true; do
    CHOICE=$(whiptail --title "AI 电脑维修助手" --menu \
        "请选一个任务（↑↓ 选择，回车确认）：" 18 62 6 \
        "1" "电脑体检（自动全面检测，推荐新手）" \
        "2" "重装系统（自动推荐最优方案）" \
        "3" "忘记开机密码" \
        "4" "备份/抢救文件" \
        "5" "硬件检测（硬盘/内存/温度）" \
        "6" "自由对话（直接说出您的问题）" \
        3>&1 1>&2 2>&3) || exit 0

    case "$CHOICE" in
        1) exec claude "$(task_prompt tijian.txt)" ;;
        2) exec claude "$(task_prompt reinstall.txt)" ;;
        3) exec claude "$(task_prompt password.txt)" ;;
        4) exec claude "$(task_prompt backup.txt)" ;;
        5) exec claude "$(task_prompt hardware.txt)" ;;
        6) exec claude ;;
    esac
done
