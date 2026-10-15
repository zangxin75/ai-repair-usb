#!/usr/bin/env bash
# check-network.sh —— 五级分级网络诊断
#
# 用途：逐级检查网络状态，每级失败输出中文原因与建议：
#   ① 网卡链路（存在 state UP 的接口）
#   ② 默认路由/DHCP（是否拿到 IP）
#   ③ DNS 解析（getent hosts tokeneff.com）
#   ④ Internet 连通性（curl 公网）
#   ⑤ 网关 API 端点（POST https://tokeneff.com/v1/messages；4xx=通过，5xx/超时=失败）
#
# 调用方：welcome.sh（第2步）、offline-menu.sh（重新检测）、Claude Code（诊断）
# 依赖命令：ip getent curl
# 选项：--quiet  只返回退出码，不输出文字（供脚本调用）
# 退出码：0=全部通过；非0=失败级别编号（1-5）
set -euo pipefail

QUIET=0
for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=1 ;;
        --help|-h)
            cat <<'EOF'
用法: check-network.sh [--quiet]
五级网络诊断：①网卡链路 ②默认路由/DHCP ③DNS解析 ④Internet连通 ⑤网关API端点。
--quiet  静默模式，只用退出码表示结果（0=通过，1-5=失败级别）。
EOF
            exit 0 ;;
        *) echo "未知参数: $arg（--help 查看用法）" >&2; exit 64 ;;
    esac
done

fail() {  # fail <级别号> <中文原因与建议>
    local lvl="$1"; shift
    if [[ $QUIET -eq 0 ]]; then
        echo "    [未通过·第${lvl}级] $*" >&2
    fi
    exit "$lvl"
}

ok() { [[ $QUIET -eq 0 ]] && echo "    [通过·第$1级] $2"; return 0; }

# ① 网卡链路
if ip link show 2>/dev/null | grep -q "state UP"; then
    ok 1 "网卡已连接"
else
    fail 1 "未检测到已连接的网卡。
建议：插好网线；无线用户请选「重新配网」连 WiFi；
板载网卡不识别时，请插 USB 网卡或用手机 USB 共享网络。"
fi

# ② 默认路由 / DHCP
if ip route 2>/dev/null | grep -q '^default'; then
    ok 2 "已获取 IP 地址（DHCP 正常）"
else
    fail 2 "网卡已连接，但没有获取到 IP 地址（自动分配失败）。
建议：检查路由器是否开启自动分配（DHCP）；重新插拔网线；
或选「重新配网」手动设置。"
fi

# ③ DNS 解析
if getent hosts tokeneff.com >/dev/null 2>&1; then
    ok 3 "域名解析正常（DNS 正常）"
else
    fail 3 "无法把网址翻译成服务器地址（DNS 解析失败）。
建议：路由器 DNS 可能异常，可重启路由器；
或选「重新配网」手动设置 DNS 为 223.5.5.5 或 119.29.29.29。"
fi

# ④ Internet 连通性
if curl -s -o /dev/null --max-time 10 https://www.baidu.com 2>/dev/null \
   || curl -s -o /dev/null --max-time 10 https://www.qq.com 2>/dev/null; then
    ok 4 "互联网连通正常"
else
    fail 4 "能解析网址，但无法访问互联网。
建议：宽带可能欠费或光猫异常；检查光猫指示灯；
手机热点用户请确认手机流量可用。"
fi

# ⑤ 网关 API 端点（探测 /v1/messages 而非首页；4xx=网关可达鉴权问题→通过；5xx/超时→失败）
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
       -X POST https://tokeneff.com/v1/messages 2>/dev/null || echo "000")
case "$CODE" in
    4*) ok 5 "AI 网关可达（HTTP $CODE，鉴权问题将在凭证步骤处理）" ;;
    *)  fail 5 "AI 网关 tokeneff.com 服务异常（HTTP ${CODE:-超时}）。
这不是您的网络问题——互联网是通的，是 AI 服务网关暂时不可用。
建议：稍后重试；或先进入离线模式使用本地维修工具。" ;;
esac

exit 0
