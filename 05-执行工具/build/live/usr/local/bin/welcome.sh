#!/usr/bin/env bash
# welcome.sh V2 —— AI 电脑维修 U盘 启动总编排脚本
#
# 用途：Live 系统自动登录后由 xfce4-terminal 自动调用，完成启动五步编排：
#   第1步 挂载 Ventoy 数据分区（mount-ventoy-data.sh → /mnt/ventoy）
#   第2步 网络五级诊断（check-network.sh；失败给「重试/重新配网/离线模式」三选）
#   第3步 凭证：读 /mnt/ventoy/config/auth_token，无则引导输入并写回（权限 600）
#   第4步 中文使用说明（结论先行，每屏 ≤7 行）
#   第5步 主菜单（main-menu.sh；离线模式传 --offline）
#   另：解包 update-claude.sh 下载的 claude-code 更新包到可写层优先加载，失败静默回退内置版
#
# 调用方：xfce4-terminal 自启动项（Live 系统自动登录后）
# 依赖命令：whiptail mount-ventoy-data.sh check-network.sh main-menu.sh offline-menu.sh nmtui
set -euo pipefail

VENTOY_MNT="/mnt/ventoy"
CONFIG_DIR="$VENTOY_MNT/config"
TOKEN_FILE="$CONFIG_DIR/auth_token"
UPDATE_PKG="$CONFIG_DIR/claude-code-latest.tar.gz"
RUNTIME_CLAUDE="/opt/claude-code-runtime"

show_help() {
    cat <<'EOF'
用法: welcome.sh
启动总编排：挂载数据分区 → 网络诊断 → 凭证配置 → 使用说明 → 主菜单。
无参数，由 Live 系统自启动调用。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

say() { echo; echo "==> $*"; }

# ---------- 第1步：挂载 Ventoy 数据分区 ----------
say "第1步/共5步：挂载 U盘 数据分区"
if ! mount-ventoy-data.sh; then
    whiptail --title "挂载失败" --msgbox \
        "未能挂载 U盘 数据分区（/mnt/ventoy）。\n配置、镜像和凭证都在该分区上。\n将进入离线模式（部分功能不可用）。" \
        12 60
    OFFLINE=1
else
    OFFLINE=0
fi

# ---------- 解包 claude-code 更新包（失败静默回退 ISO 内置版） ----------
if [[ $OFFLINE -eq 0 && -f "$UPDATE_PKG" ]]; then
    sudo mkdir -p "$RUNTIME_CLAUDE" 2>/dev/null || true
    if sudo tar -xzf "$UPDATE_PKG" -C "$RUNTIME_CLAUDE" 2>/dev/null \
       && [[ -x "$RUNTIME_CLAUDE/bin/claude" ]]; then
        export PATH="$RUNTIME_CLAUDE/bin:$PATH"
        echo "    已加载 U盘 内的新版 AI 助手。"
    else
        echo "    更新包不可用，使用系统内置版本。" >&2
        sudo rm -rf "$RUNTIME_CLAUDE" 2>/dev/null || true
    fi
fi

# ---------- 第2步：网络五级诊断 ----------
OFFLINE_NET=0
say "第2步/共5步：检查网络与 AI 网关"
while true; do
    if check-network.sh; then
        echo "    网络与 AI 网关连接正常。"
        break
    fi
    # check-network.sh 已输出分级中文原因与建议
    CHOICE=$(whiptail --title "网络检查未通过" --menu \
        "网络或 AI 网关未连通。请选择下一步：" 15 60 3 \
        "1" "重试（重新检测）" \
        "2" "重新配网（WiFi/有线设置）" \
        "3" "进入离线模式（本地工具可用）" \
        3>&1 1>&2 2>&3) || { OFFLINE_NET=1; break; }
    case "$CHOICE" in
        1) continue ;;
        2) nmtui || true; continue ;;
        3) OFFLINE_NET=1; break ;;
    esac
done

if [[ $OFFLINE_NET -eq 1 ]]; then
    exec offline-menu.sh
fi

# ---------- 第3步：凭证 ----------
say "第3步/共5步：检查 AI 服务凭证"
TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE" || true)
fi
if [[ -z "$TOKEN" ]]; then
    whiptail --title "首次配置" --msgbox \
        "这是首次使用，需要配置 AI 服务凭证（token）。\n凭证由 tokeneff.com 服务方签发，请向服务方获取。\n将保存在 U盘 的 config/auth_token（仅本机可读）。\n注意：凭证明文存于 U盘，U盘遗失请立即作废该凭证。" \
        15 64
    while true; do
        TOKEN=$(whiptail --title "输入凭证" --inputbox \
            "请粘贴您的 AI 服务凭证（token）：" 10 60 3>&1 1>&2 2>&3) || {
            whiptail --title "无法继续" --msgbox "未配置凭证，AI 功能不可用，将进入离线模式。" 10 60
            exec offline-menu.sh
        }
        TOKEN=$(echo "$TOKEN" | tr -d '[:space:]')
        [[ -n "$TOKEN" ]] && break
        whiptail --title "凭证为空" --msgbox "凭证不能为空，请重新输入。" 8 50
    done
    mkdir -p "$CONFIG_DIR"
    umask 077
    printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE" || true   # exFAT 不支持权限位，尽力而为
    echo "    凭证已保存到 U盘 config/auth_token。"
fi

# 显式 export 网关环境变量（不依赖 profile.d 时序 —— 设计 §2.2.1-C）
export ANTHROPIC_BASE_URL="https://tokeneff.com"
export ANTHROPIC_AUTH_TOKEN="$TOKEN"

# ---------- 第4步：使用说明 ----------
say "第4步/共5步：使用说明"
whiptail --title "AI 电脑维修助手" --msgbox \
"欢迎使用！请记住三件事：
1. 全程用中文对话，看不懂就问。
2. 格式化、删分区等危险操作前，一定先让您确认。
3. 本机硬盘里的重要文件，动手前先备份。
按回车进入主菜单。" 14 60

# ---------- 第5步：主菜单 ----------
say "第5步/共5步：进入主菜单"
exec main-menu.sh
