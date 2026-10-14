#!/usr/bin/env bash
# ai-assistant.sh —— 桌面「AI 维修助手」图标入口（v0.3）
#
# 设计原则：AI 时代产品，节约人的心智 —— 有 token 直接进 Claude 对话（agent 优先），
# 没配好才回退 welcome.sh 五步编排（菜单/对话兜底）。
#
# 调用方：桌面快捷方式 /etc/skel/Desktop/AI维修助手.desktop（xfce4-terminal 启动）
# 依赖命令：mount-ventoy-data.sh claude welcome.sh
set -euo pipefail

VENTOY_MNT="/mnt/ventoy"
TOKEN_FILE="$VENTOY_MNT/config/auth_token"

show_help() {
    cat <<'EOF'
用法: ai-assistant.sh
桌面一键入口：已配置 token 直接进入 AI 对话，否则回退启动编排。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

# token 可能已在开机编排里就位（分区已挂载）；本入口冷启动也要能用
if [[ ! -f "$TOKEN_FILE" ]]; then
    mount-ventoy-data.sh 2>/dev/null || true
fi

if [[ -f "$TOKEN_FILE" ]] && [[ -n "$(tr -d '[:space:]' < "$TOKEN_FILE" 2>/dev/null || true)" ]]; then
    export ANTHROPIC_BASE_URL="https://tokeneff.com"
    export ANTHROPIC_AUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    export PATH="/opt/claude-code-runtime/bin:$PATH"
    exec claude "（系统流程，请直接开始执行，不要复述任务）
你好，我是这台电脑的 AI 维修助手。请先简短自我介绍（一句话），然后列出你最擅长处理的几类电脑问题（重装系统、数据备份、密码重置、硬件体检等），等待用户描述问题后开始干活。全程中文。"
fi

# 未配置 token → 完整启动编排（网络诊断/凭证引导/主菜单）
exec welcome.sh
