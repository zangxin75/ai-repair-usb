#!/usr/bin/env bash
# repair-on-linux.sh 版本: 0.2.0  (AI 电脑维修 U盘 · 场景③ Linux 在线维修启动器)
# =====================================================================
# 创建日期: 2026-11-20
# 版本: 0.2.0（环境自审：不在本项目U盘上运行即指路——已挂载成品U盘给出确切命令、无U盘则给制作命令；交互 read 绑 /dev/tty。0.1.0 初版见 git history）
# 状态: 定稿实现（设计三轮 critic 审计 6.5→7.5→8.5 ACCEPT，2026-11-20）
# 作者: Claude Code + kt
# 设计依据: 04-design/技术方案_AI电脑维修U盘_场景三Linux在线维修启动器_20261120.md
# 兼容: bash 4+（Linux 桌面发行版通用）；无 jq/python3 时自动降级 sed 第三层
# 用法: U盘插到 Linux 电脑后，打开终端:
#         cd <U盘路径> && bash repair-on-linux.sh
#       维修会话自动请求 sudo（拒绝则降级只读诊断）；--repair 为启动器内部
#       sudo 重入参数，请勿手工传入。
# 注意: settings.conf 的 CONFIG_OVERRIDE=1 是历史无消费者字段（保留兼容存量盘）。
# =====================================================================
set -u

# ---------------- 全局常量 ----------------
SCRIPT_VERSION="0.2.0"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
USB_ROOT="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd -P)"
CONFIG_DIR="$USB_ROOT/config"
DEFAULT_GATEWAY="https://tokeneff.com"
HTTP_TIMEOUT=30
NET_MAX_RETRY=3
LOW_BALANCE_THRESHOLD=2000000   # <10% of 周 2000 万（与 ps1 同基线）
GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
READONLY_PROMPT='【只读诊断模式】你处于只读诊断模式：禁止执行任何写操作（不改系统配置、不删改文件、不停启用服务/驱动），只允许收集信息、诊断并给出文字建议。'

# ---------------- 输出工具 ----------------
step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn() { printf '    \033[33m[警告] %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m[失败] %s\033[0m\n' "$1"; }
ask() {  # 交互读取：stdin 是终端（正常U盘运行）直读；非终端且 /dev/tty 可用（curl|bash 单跑，
    # stdin 是脚本管道，裸 read 会吞脚本行）绑终端；其余（测试管道喂答案 / AI_REPAIR_ASK_STDIN=1）回落 stdin
    if [ "${AI_REPAIR_ASK_STDIN:-0}" != 1 ] && [ ! -t 0 ] && builtin read "$@" < /dev/tty 2>/dev/null; then
        return 0
    fi
    builtin read "$@"
}
pause() { local _=''; printf '按回车键继续... '; ask -r _ || true; printf '\n'; }
die() {
    fail "$1"
    [ -n "${2:-}" ] && printf '\033[33m建议: %s\033[0m\n' "$2"
    pause
    exit 1
}

usage() {
    sed -n '2,22p' "$SCRIPT_PATH" 2>/dev/null || true
    printf '\n用法: bash repair-on-linux.sh [--repair]\n'
}

# ---------------- 参数 ----------------
REPAIR_MODE=0
case "${1:-}" in
    --repair) REPAIR_MODE=1 ;;
    --help|-h) usage; exit 0 ;;
    '') ;;
    *) fail "未知参数: ${1:-}"; usage; exit 1 ;;
esac
# --repair 为 sudo 重入专用：非 root 持有即拒绝（防误用）
if [ "$REPAIR_MODE" = 1 ] && [ "$(id -u)" -ne 0 ]; then
    fail '--repair 参数需要 root（由启动器自动使用，请勿手工传入）。'
    exit 1
fi

# ---------------- 环境自审：贴错命令 / 装错场景自动纠偏 ----------------
# 启动器只应在本项目U盘上运行；curl 单跑 / 拷去了普通U盘时在此指路，
# 而不是在后面以「找不到 config/settings.conf」这种晦涩方式失败。
audit_is_project_root() {   # $1=目录：任一成品U盘特征命中即真
    [ -f "$1/config/settings.conf" ] && return 0
    [ -d "$1/config" ] && return 0
    [ -f "$1/repair-on-windows.ps1" ] && return 0
    [ -f "$1/.ai-repair-maker-session" ] && return 0
    return 1
}
if [ "$REPAIR_MODE" -eq 0 ] && ! audit_is_project_root "$USB_ROOT"; then
    _found=""
    for _root in ${AI_REPAIR_AUDIT_ROOTS:-/media/*/* /media/* /run/media/*/* /mnt/*}; do
        if [ -d "$_root" ] && audit_is_project_root "$_root"; then _found="$_root"; break; fi
    done
    fail "启动器不在本项目的U盘上运行（当前位置: ${USB_ROOT}）。"
    if [ -n "$_found" ]; then
        printf '    检测到本项目的U盘已插入，开始维修请运行:\n        bash "%s/repair-on-linux.sh"\n' "$_found"
    else
        printf '    · 要【制作 / 升级U盘】:  curl -sL https://usb.tokeneff.com/maker/usb-v1.0.sh | sudo bash\n'
        printf '    · 要【修这台电脑】: 请插入本项目的U盘，在其根目录运行:  bash repair-on-linux.sh\n'
    fi
    pause
    exit 1
fi

# ---------------- 临时目录与清理（trap） ----------------
# 安全红线：一律 mktemp 随机目录 + 700，绝无固定路径（共享 /tmp 固定路径 +
# root 执行 = 本地提权通道，设计三轮审计 B1/NEW-2）；两级进程各自建各自清。
WORK=""
FALLBACK_DIR=""
CLEANED=0
KEEP_WORK=0          # enterprise 盘用户选择保留时置 1
WORK_CLEAN_CONFIRMED=0
cleanup() {
    [ "${CLEANED:-0}" = 1 ] && return 0
    CLEANED=1
    if [ "${RECORD_MODE:-customer}" = "enterprise" ] \
        && [ "${KEEP_WORK:-0}" != 1 ] && [ "${WORK_CLEAN_CONFIRMED:-0}" != 1 ]; then
        # 企业盘异常退出（非 [0] 正常路径）：不静默删会话历史
        [ -n "${WORK:-}" ] && printf '\n[企业运维模式] 会话历史保留于: %s（未确认清理，请自行处理）\n' "$WORK" >&2
    else
        [ -n "${WORK:-}" ] && rm -rf -- "$WORK" 2>/dev/null
    fi
    [ -n "${FALLBACK_DIR:-}" ] && rm -rf -- "$FALLBACK_DIR" 2>/dev/null
    unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_API_KEY \
        ANTHROPIC_OAUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL \
        ANTHROPIC_DEFAULT_MODEL CLAUDE_CONFIG_DIR 2>/dev/null || true
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# ---------------- 定位与配置 ----------------
if [ ! -f "$CONFIG_DIR/settings.conf" ]; then
    die "未在脚本所在目录找到 config/settings.conf（定位到: $USB_ROOT）。" \
        '请确认本脚本位于 AI 维修U盘 数据分区根目录，未被复制到电脑本地运行。'
fi
ok "U盘定位成功: $USB_ROOT"

# settings.conf 解析（规则同方案 5.1：KEY=VALUE、整行注释；KEY 两侧空格警告容忍）
declare -A CONF=()
read_settings_conf() {
    local raw line key val lineno=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        lineno=$((lineno + 1))
        line="${raw#"${raw%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        case "$line" in *=*) ;; *)
            warn "settings.conf 第 $lineno 行不符合 KEY=VALUE 格式（无等号），已忽略: $line"
            continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        [ -z "$key" ] && continue
        CONF["$key"]="$val"
    done < "$CONFIG_DIR/settings.conf"
}
read_settings_conf
for required in ACTIVATE_URL BALANCE_URL; do
    if [ -z "${CONF[$required]:-}" ]; then
        die "settings.conf 缺少必需配置项 $required（方案 5.1）。" \
            '请用最新制作器重新制作U盘，或在 config/settings.conf 中补齐该行。'
    fi
done
RECORD_MODE="${CONF[RECORD_MODE]:-customer}"
ok "配置解析成功（记录模式: $RECORD_MODE）"

# ---------------- JSON 三层解析（jq → python3 → sed/grep） ----------------
# 双缺 jq/python3 的客户机走 sed 第三层仍可跑通全流程（含数字字段供余额闸门）。
json_field() { # $1=字段名 $2=JSON 文件 → stdout 值（字符串/数字；布尔用 json_bool）
    local f="$1" file="$2" v=""
    if command -v jq >/dev/null 2>&1; then
        v="$(jq -r --arg f "$f" '.[$f] // empty' "$file" 2>/dev/null)"
    elif command -v python3 >/dev/null 2>&1; then
        v="$(python3 -c 'import json,sys
try:
    v=json.load(open(sys.argv[2])).get(sys.argv[1])
    print("" if v is None else v)   # 0 必须原样输出（余额耗尽闸门依赖）
except Exception: pass' "$f" "$file" 2>/dev/null)"
    else
        v="$(sed -n "s/.*\"$f\": *\"\([^\"]*\)\".*/\1/p" "$file" 2>/dev/null | head -n1)"
        if [ -z "$v" ]; then
            v="$(sed -n "s/.*\"$f\": *\([0-9][0-9]*\).*/\1/p" "$file" 2>/dev/null | head -n1)"
        fi
    fi
    printf '%s' "$v"
}
json_bool() { # $1=字段名 $2=JSON 文件 → 0=true 1=false/缺失
    local f="$1" file="$2" v=""
    if command -v jq >/dev/null 2>&1; then
        v="$(jq -r --arg f "$f" '.[$f]' "$file" 2>/dev/null)"
    elif command -v python3 >/dev/null 2>&1; then
        v="$(python3 -c 'import json,sys
try: print(str(json.load(open(sys.argv[2])).get(sys.argv[1],False)).lower())
except Exception: print("false")' "$f" "$file" 2>/dev/null)"
    else
        if grep -q "\"$f\": *true" "$file" 2>/dev/null; then v="true"; else v="false"; fi
    fi
    [ "$v" = "true" ]
}
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---------------- 网关封装（对等 ps1 0.5.6：不用 -f，仅网络层重试） ----------------
AUTH_KEY=""
GW_CODE=0
gw_curl() { # $1=method $2=url [$3=JSON body]；HTTP 任一状态码返回 0 且置 GW_CODE；网络耗尽返回 1
    local method="$1" url="$2" body="${3:-}" i rc
    local body_file="$WORK/gw-body.json"
    : > "$body_file" 2>/dev/null || true
    for i in $(seq 1 "$NET_MAX_RETRY"); do
        local -a hdrs=(-X "$method" -H 'X-Requested-With: XMLHttpRequest')
        [ -n "$body" ] && hdrs+=(-H 'Content-Type: application/json' -d "$body")
        [ -n "$AUTH_KEY" ] && hdrs+=(-H "Authorization: Bearer $AUTH_KEY")
        rc=0
        # 不用 -f：4xx 响应体必须保留（403 detail 透出依赖响应体）
        GW_CODE="$(curl -sS -o "$body_file" -w '%{http_code}' --max-time "$HTTP_TIMEOUT" \
            "${hdrs[@]}" "$url" 2>>"$WORK/gw-curl.err")" || rc=$?
        if [ "$rc" -eq 0 ]; then return 0; fi
        warn "网关请求失败（第 $i/$NET_MAX_RETRY 次）: $url"
        [ "$i" -lt "$NET_MAX_RETRY" ] && sleep $((5 * i))
    done
    return 1
}

show_offline_fallback() {
    printf '\n\033[33m-----------------------------------------------------------\033[0m\n'
    printf '\033[33m 兜底方案：请用此U盘重启电脑进入维修系统（场景②离线维修），\033[0m\n'
    printf '\033[33m 开机按启动菜单键(F12/F9/Esc)选择 U盘 启动，\033[0m\n'
    printf '\033[33m 无需在 Linux 内安装任何软件，也不依赖网络网关。\033[0m\n'
    printf '\033[33m-----------------------------------------------------------\033[0m\n'
}
show_upgrade_hint() {
    local url=""
    if [ -f "$USB_ROOT/upgrade-url.txt" ]; then
        url="$(tr -d '[:space:]' < "$USB_ROOT/upgrade-url.txt" 2>/dev/null)"
    fi
    printf '    \033[33m升级 / 购买入口: %s\033[0m\n' "${url:-https://tokeneff.com}"
}

# ---------------- 采集字段 ----------------
get_usb_sn() {
    local dev="" sn=""
    dev="$(findmnt -n -o SOURCE "$USB_ROOT" 2>/dev/null | head -n1)"
    if [ -z "$dev" ]; then
        dev="$(df --output=source "$USB_ROOT" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    fi
    if [ -n "$dev" ] && command -v udevadm >/dev/null 2>&1; then
        sn="$(udevadm info --query=property --name "$dev" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p' | head -n1)"
    fi
    if [ -z "$sn" ] && [ -n "$dev" ] && command -v lsblk >/dev/null 2>&1; then
        sn="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    fi
    printf '%s' "${sn:-UNKNOWN}"
}
get_machine_fp() {
    # 设计 §4 如实降级：dmidecode 与 /sys/.../board_serial 非 root 均 0400 不可读，
    # 而激活发生在低权进程 → Linux v0.1 指纹常态 UNKNOWN（仅观察字段，不阻断）。
    local fp=""
    if [ "$(id -u)" -eq 0 ] && command -v dmidecode >/dev/null 2>&1; then
        fp="$(dmidecode -s baseboard-serial-number 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -z "$fp" ] && [ -r /sys/class/dmi/id/board_serial ]; then
        fp="$(tr -d '[:space:]' < /sys/class/dmi/id/board_serial 2>/dev/null)"
    fi
    printf '%s' "${fp:-UNKNOWN}"
}
get_maker_version() {
    local v=""
    if [ -f "$USB_ROOT/maker_version" ]; then
        v="$(tr -d '[:space:]' < "$USB_ROOT/maker_version" 2>/dev/null)"
    fi
    printf '%s' "${v:-unknown}"
}

# ---------------- 凭证读写 ----------------
read_auth_token() {
    local t=""
    if [ -f "$CONFIG_DIR/auth_token" ]; then
        t="$(tr -d '[:space:]' < "$CONFIG_DIR/auth_token" 2>/dev/null)"
    fi
    printf '%s' "$t"
}
write_auth_token() { # $1=key（无 BOM UTF-8 + 末尾换行；600 尽力而为，exFAT 无权限位时容忍）
    local old_umask
    old_umask="$(umask)"
    umask 077
    if ! printf '%s\n' "$1" > "$CONFIG_DIR/auth_token" 2>/dev/null; then
        warn 'auth_token 写入失败（U盘写保护？）——本次会话可继续，但凭证不会持久化'
    else
        chmod 600 "$CONFIG_DIR/auth_token" 2>/dev/null || true
    fi
    umask "$old_umask"
}
write_batch_id() { # $1=batch_id（settings.conf 幂等写回；sed -i 同卷 tmp+rename，exFAT 原子）
    local bid
    bid="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')"   # 防服务端异常值注入 sed
    [ -n "$bid" ] || return 0
    if grep -q '^BATCH_ID=' "$CONFIG_DIR/settings.conf" 2>/dev/null; then
        sed -i "s/^BATCH_ID=.*/BATCH_ID=$bid/" "$CONFIG_DIR/settings.conf" 2>/dev/null \
            || warn 'BATCH_ID 更新失败（settings.conf 不可写）'
    else
        printf 'BATCH_ID=%s\n' "$bid" >> "$CONFIG_DIR/settings.conf" 2>/dev/null \
            || warn 'BATCH_ID 追加失败（settings.conf 不可写）'
    fi
}

# ---------------- agents.json 闸门（claude.userDeclined=true 禁在线拉取） ----------------
claude_declined() {
    local f="$CONFIG_DIR/agents.json"
    [ -f "$f" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        [ "$(jq -r '.claude.userDeclined // false' "$f" 2>/dev/null)" = "true" ]
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try: print(str(json.load(open(sys.argv[1])).get("claude",{}).get("userDeclined",False)).lower())
except Exception: print("false")' "$f" 2>/dev/null | grep -q '^true$'
    else
        # sed 层：截取 "claude" 块（到首个 }，兼容紧凑/多行两种写法）再查 userDeclined:true
        grep -o '"claude"[^}]*}' "$f" 2>/dev/null | grep -q '"userDeclined": *true'
    fi
}
CLAUDE_DECLINED=0
claude_declined && CLAUDE_DECLINED=1

# ---------------- 工作目录（定位成功后创建） ----------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-repair.XXXXXX")" \
    || die '无法创建本机临时目录。' '请检查 $TMPDIR / /tmp 可写后重试。'
chmod 700 "$WORK"

# ---------------- 激活 / 余额 / 邮箱验证 ----------------
do_activation() {
    step '首次使用：正在激活本U盘的免费维修额度 ...'
    local sn fp promo input body key bid detail
    sn="$(get_usb_sn)"; fp="$(get_machine_fp)"
    printf '    U盘序列号: %s\n' "$sn"
    printf '    机器指纹:   %s\n' "$fp"
    promo="${CONF[PROMO_CODE]:-}"
    if [ -n "$promo" ]; then
        IFS= ask -rp "推广码（直接回车使用默认值 $promo）: " input || input=""
        input="$(printf '%s' "$input" | tr -d '[:space:]')"
        [ -n "$input" ] && promo="$input"
    else
        IFS= ask -rp '推广码（可留空直接回车跳过）: ' input || input=""
        promo="$(printf '%s' "$input" | tr -d '[:space:]')"
    fi
    body="{\"usb_sn\":\"$(json_esc "$sn")\",\"machine_fp\":\"$(json_esc "$fp")\"\
,\"maker_version\":\"$(json_esc "$(get_maker_version)")\""
    [ -n "$promo" ] && body="$body,\"promo_code\":\"$(json_esc "$promo")\""
    body="$body}"
    if ! gw_curl POST "${CONF[ACTIVATE_URL]}" "$body"; then
        fail '激活失败: 网络不可达（已重试）'
        show_offline_fallback
        die '网关暂不可用，Linux 在线维修（场景③）完全依赖网关，本次无法继续。' \
            '请按上方提示使用U盘离线维修（场景②），或稍后网络恢复再试。'
    fi
    case "$GW_CODE" in
        2*)
            key="$(json_field key "$WORK/gw-body.json")"
            [ -n "$key" ] || die '激活响应异常（缺少 key 字段）。' '请稍后重试；若持续失败请联系客服。'
            AUTH_KEY="$key"
            write_auth_token "$key"
            bid="$(json_field batch_id "$WORK/gw-body.json")"
            if [ -n "$bid" ]; then
                write_batch_id "$bid"
                ok "批次已记录: $bid"
            fi
            ok '激活成功，凭证已写回U盘（auth_token）'
            return 0 ;;
        429)
            die '该网络今日激活次数已达上限（每 IP 每日限量）。' '请明日再试，或更换网络环境后重试。' ;;
        403)
            detail="$(json_field detail "$WORK/gw-body.json")"
            if [ -n "$detail" ]; then
                die "激活请求被服务端拒绝：$detail" '请联系支持并提供上方的U盘序列号，勿自行重做U盘。'
            else
                die '激活请求被服务端拒绝（HTTP 403）。' '请联系支持并提供上方的U盘序列号，勿自行重做U盘。'
            fi ;;
        423)
            die '该U盘已被风控暂停使用。' '请联系客服提供U盘序列号以核实处理。' ;;
        409)
            fail '本U盘免费额度有效期已过（12 个月）。'
            show_upgrade_hint
            die '请走付费/续费通道后重试。' '免费 key 到期后不再重发，详见上方升级入口。' ;;
        *)
            fail "激活失败: HTTP $GW_CODE"
            show_offline_fallback
            die '网关暂不可用，Linux 在线维修（场景③）完全依赖网关，本次无法继续。' \
                '请按上方提示使用U盘离线维修（场景②），或稍后网络恢复再试。' ;;
    esac
}

BAL_REMAINING=""; BAL_MONTHLY=""; BAL_EXPIRES=""; EXHAUSTED=0; LOW=0; BAL_VERIFY_REQUIRED=0
query_balance() {
    step '正在查询剩余额度 ...'
    if ! gw_curl GET "${CONF[BALANCE_URL]}"; then
        fail '余额查询失败: 网络不可达（已重试）'
        show_offline_fallback
        die '网关暂不可用，Linux 在线维修（场景③）完全依赖网关，本次无法继续。' \
            '请按上方提示使用U盘离线维修（场景②），或稍后网络恢复再试。'
    fi
    case "$GW_CODE" in
        2*) ;;
        401|403)
            die '凭证已失效（key 被吊销或校验失败）。' '请删除U盘 config/auth_token 后重新运行以重新激活，或联系客服。' ;;
        *)
            fail "余额查询失败: HTTP $GW_CODE"
            show_offline_fallback
            die '网关暂不可用，Linux 在线维修（场景③）完全依赖网关，本次无法继续。' \
                '请按上方提示使用U盘离线维修（场景②），或稍后网络恢复再试。' ;;
    esac
    BAL_REMAINING="$(json_field remaining_weekly "$WORK/gw-body.json")"
    BAL_MONTHLY="$(json_field total_used_monthly "$WORK/gw-body.json")"
    BAL_EXPIRES="$(json_field expires_at "$WORK/gw-body.json")"
    ok "本周剩余额度: ${BAL_REMAINING:-?} token（本月累计: ${BAL_MONTHLY:-?}）"
    EXHAUSTED=0; LOW=0
    case "$BAL_REMAINING" in
        ''|*[!0-9]*) ;;   # 解析失败不闸门（网关侧周额度硬顶兜底）
        0) EXHAUSTED=1 ;;
        *) [ "$BAL_REMAINING" -lt "$LOW_BALANCE_THRESHOLD" ] && LOW=1 ;;
    esac
    if [ "$EXHAUSTED" = 1 ]; then
        warn '本周免费额度已用完。'
        show_upgrade_hint
        printf '    \033[33m升级套餐后即可继续使用，无任何隐性降速。\033[0m\n'
    elif [ "$LOW" = 1 ]; then
        warn "本周额度已不足 10%（剩余 $BAL_REMAINING token），请合理安排使用或提前升级。"
        show_upgrade_hint
    fi
    BAL_VERIFY_REQUIRED=0
    json_bool verification_required "$WORK/gw-body.json" && BAL_VERIFY_REQUIRED=1
    return 0
}

email_verify() { # → 0=已验证 1=未完成（不阻断，调用方警告）
    step '本U盘用量已触发邮箱验证（免费额度辅助风控）'
    printf '    请输入您的邮箱收取验证码（验证一次后解除后续验证要求，限额不变）。\n'
    local email code verify_url
    IFS= ask -rp '邮箱地址: ' email || email=""
    email="$(printf '%s' "$email" | tr -d '[:space:]')"
    [ -n "$email" ] || { warn '未输入邮箱，本次无法完成验证。'; return 1; }
    verify_url="${CONF[BALANCE_URL]%/balance}/verify"
    if ! gw_curl POST "$verify_url" \
        "{\"key\":\"$(json_esc "$AUTH_KEY")\",\"email\":\"$(json_esc "$email")\"}"; then
        warn '验证码发送失败（网络不可达）。'
        return 1
    fi
    case "$GW_CODE" in
        2*)
            if json_bool already_verified "$WORK/gw-body.json"; then
                ok '该凭证此前已通过邮箱验证，无需复核'
                return 0
            fi
            ok '验证码已发送（有效期 10 分钟，请查收邮箱，注意垃圾箱）' ;;
        429)
            warn '发送过于频繁（60 秒冷却 / 每日限 5 封），请稍后再试。'
            return 1 ;;
        *)
            warn "验证码发送失败（HTTP $GW_CODE）。"
            return 1 ;;
    esac
    IFS= ask -rp '请输入收到的 6 位验证码（直接回车放弃）: ' code || code=""
    code="$(printf '%s' "$code" | tr -d '[:space:]')"
    [ -n "$code" ] || return 1
    if gw_curl POST "$verify_url/confirm" \
        "{\"key\":\"$(json_esc "$AUTH_KEY")\",\"code\":\"$(json_esc "$code")\"}" \
        && [ "$GW_CODE" = 200 ]; then
        ok '邮箱验证通过'
        return 0
    fi
    warn '验证码错误或已过期（单码最多尝试 5 次，超限作废需重发）。可重新查询余额再试。'
    return 1
}

# ---------------- 引擎获取链（①U盘便携 → ②本机 → ③在线 GCS） ----------------
stage_engine() { # $1=引擎源文件 → 置 CLAUDE_CMD；0=就绪 1=失败（含 noexec 兜底）
    CLAUDE_CMD=""
    cp "$1" "$WORK/claude" 2>/dev/null || return 1
    chmod +x "$WORK/claude" 2>/dev/null || true
    if "$WORK/claude" --version >/dev/null 2>&1; then
        CLAUDE_CMD="$WORK/claude"
        return 0
    fi
    # /tmp noexec 兜底：随机目录（root 侧显式 /root/.local/share，不依赖 $HOME/env_keep）
    local base
    if [ "$(id -u)" -eq 0 ]; then
        base="/root/.local/share"
    else
        base="${XDG_DATA_HOME:-$HOME/.local/share}"
    fi
    mkdir -p "$base" 2>/dev/null || return 1
    FALLBACK_DIR="$(mktemp -d "$base/ai-repair-work.XXXXXX")" || return 1
    chmod 700 "$FALLBACK_DIR"
    if cp "$1" "$FALLBACK_DIR/claude" 2>/dev/null && chmod +x "$FALLBACK_DIR/claude" 2>/dev/null \
        && "$FALLBACK_DIR/claude" --version >/dev/null 2>&1; then
        CLAUDE_CMD="$FALLBACK_DIR/claude"
        return 0
    fi
    rm -rf -- "$FALLBACK_DIR" 2>/dev/null
    FALLBACK_DIR=""
    return 1
}
online_engine() {
    step '在线下载 Claude Code 引擎（官方分发桶 linux-x64，约 294MB，仅需一次）...'
    local ver sum i actual
    local tmp="$WORK/claude-dl"
    ver="$(curl -fsSL --connect-timeout 15 --max-time 60 "$GCS_BASE/stable" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$ver" ]; then
        warn '官方分发桶不可达（需可达 storage.googleapis.com 的网络）。'
        return 1
    fi
    # sed 范围模式：块内取 linux-x64 checksum（实测官方 manifest 为多行 pretty-print）
    sum="$(curl -fsSL --connect-timeout 15 --max-time 60 "$GCS_BASE/$ver/manifest.json" 2>/dev/null \
        | sed -n '/"linux-x64":/,/}/s/.*"checksum": "\([0-9a-f]*\)".*/\1/p' | head -n1)"
    if [ -z "$sum" ]; then
        warn '无法取得 linux-x64 官方校验值，放弃在线下载。'
        return 1
    fi
    for i in $(seq 1 "$NET_MAX_RETRY"); do
        if curl -fSL --connect-timeout 15 --max-time 1800 -o "$tmp" \
            "$GCS_BASE/$ver/linux-x64/claude" 2>/dev/null; then
            actual="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"
            if [ -n "$actual" ] && [ "${actual,,}" = "${sum,,}" ]; then
                if stage_engine "$tmp"; then
                    rm -f "$tmp"
                    ok "在线引擎就绪（v$ver，官方 sha256 校验通过）"
                    return 0
                fi
                warn '下载完成但无法在本机执行（临时目录 noexec？）'
                rm -f "$tmp"
                return 1
            fi
            warn "在线引擎 sha256 校验失败（第 $i 次）"
            rm -f "$tmp"
        else
            warn "在线下载失败（第 $i/$NET_MAX_RETRY 次）"
        fi
        [ "$i" -lt "$NET_MAX_RETRY" ] && sleep $((5 * i))
    done
    return 1
}
resolve_engine() { # → 置 CLAUDE_CMD；0=就绪 1=不可用
    CLAUDE_CMD=""
    local p="$USB_ROOT/bin/claude-linux" good=0 want actual
    if [ -f "$p" ]; then
        if [ -f "$p.sha256" ]; then
            want="$(tr -d '[:space:]' < "$p.sha256" 2>/dev/null)"
            actual="$(sha256sum "$p" 2>/dev/null | awk '{print $1}')"
            if [ -n "$want" ] && [ "${actual,,}" = "${want,,}" ]; then
                good=1
            else
                warn 'bin/claude-linux sha256 旁车校验失败，放弃便携引擎'
            fi
        elif [ "$(stat -c%s "$p" 2>/dev/null || printf '0')" -gt 100000000 ]; then
            good=1   # 旁车缺失回落 >100MB 尺寸判据（对齐 ps1 便携判据）
        else
            warn 'bin/claude-linux 尺寸不足（<100MB），疑似损坏'
        fi
        if [ "$good" = 1 ]; then
            if stage_engine "$p"; then
                ok '引擎就绪（U盘便携 bin/claude-linux）'
                return 0
            fi
            warn '便携引擎无法在本机执行（noexec？），尝试回落链'
        fi
    fi
    if [ "$CLAUDE_DECLINED" = 1 ]; then
        warn '此盘未安装 Claude 引擎（制作时未勾选）。重跑制作命令可补装。'
        return 1
    fi
    if command -v claude >/dev/null 2>&1; then
        CLAUDE_CMD="claude"
        ok '引擎就绪（本机已装 claude）'
        return 0
    fi
    online_engine || { show_offline_fallback; return 1; }
    return 0
}

# ---------------- 会话启动 ----------------
start_session() { # $1 = readonly|repair|office|code
    local mode="$1" sp="" office_md
    if ! resolve_engine; then
        pause
        return 1
    fi
    export ANTHROPIC_BASE_URL="${CONF[GATEWAY_BASE_URL]:-$DEFAULT_GATEWAY}"
    export ANTHROPIC_AUTH_TOKEN="$AUTH_KEY"
    unset ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN ANTHROPIC_DEFAULT_MODEL 2>/dev/null || true
    export ANTHROPIC_MODEL='claude-sonnet-5'
    export ANTHROPIC_SMALL_FAST_MODEL='claude-sonnet-5'
    export DISABLE_AUTOUPDATER=1
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    export CLAUDE_CONFIG_DIR="$WORK/claude-config"
    mkdir -p "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
    if [ -d "$CONFIG_DIR/claude-config" ]; then
        cp -r "$CONFIG_DIR/claude-config/." "$CLAUDE_CONFIG_DIR/" 2>/dev/null || true
    fi
    if [ -d "$CONFIG_DIR/claude-skills" ]; then
        mkdir -p "$CLAUDE_CONFIG_DIR/skills" 2>/dev/null || true
        cp -r "$CONFIG_DIR/claude-skills/." "$CLAUDE_CONFIG_DIR/skills/" 2>/dev/null || true
    fi
    local -a args=()
    if [ -f "$USB_ROOT/CLAUDE.md" ]; then
        sp="$USB_ROOT/CLAUDE.md"
    elif [ -f "$CONFIG_DIR/claude-config/CLAUDE.md" ]; then
        sp="$CONFIG_DIR/claude-config/CLAUDE.md"
    fi
    # 现役盘两源常皆不存在 → 裸启动（与 Windows 版同处境）
    [ -n "$sp" ] && args+=(--system-prompt "$(cat "$sp")")
    case "$mode" in
        readonly)
            step '启动只读诊断会话（禁止写操作，仅收集信息与给出建议）'
            args+=(--append-system-prompt "$READONLY_PROMPT") ;;
        office)
            step '启动办公助手会话（写文档/表格/文案）'
            office_md="$CONFIG_DIR/office/CLAUDE.md"
            if [ -f "$office_md" ]; then
                args+=(--append-system-prompt "$(cat "$office_md")")
            else
                warn 'config/office/CLAUDE.md 缺失，将以通用模式启动（无人格注入）。'
            fi ;;
        code)
            step '启动编码会话（软件开发/脚本，完全控制权限）'
            printf '    \033[33m[权限] 已授完全控制（--dangerously-skip-permissions）：文件读写/命令执行不再逐条确认\033[0m\n'
            args+=(--dangerously-skip-permissions) ;;
        repair)
            step '启动维修会话' ;;
    esac
    "$CLAUDE_CMD" ${args[@]+"${args[@]}"}
    printf '\n'
    ok '会话已结束，按回车返回'
    pause
    return 0
}

# ---------------- 维修会话（sudo 子进程重入；rc≠0 一律降级只读） ----------------
run_repair_session() {
    if [ "$EXHAUSTED" = 1 ]; then
        warn '本周免费额度已用完，无法进入维修会话。'
        show_upgrade_hint
        pause
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        start_session repair
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        warn '本机无 sudo，无法提权 —— 本次仅允许只读诊断类任务。'
        start_session readonly
        return 0
    fi
    warn '维修操作需要管理员权限，正在请求 sudo（请输入密码授权；取消则本次降级为只读诊断）...'
    # 子进程调用（非 exec）：sudo 失败 rc≠0 可降级；低权进程存活管理自己的 trap 清理
    if sudo bash "$SCRIPT_PATH" --repair; then
        ok '维修会话已结束（root 侧已自动清理），本次使用完成'
        exit 0   # 触发本进程 trap 清理
    fi
    warn '未获得管理员授权 —— 本次仅允许只读诊断类任务。'
    start_session readonly
    return 0
}

session_gate() { # $1=mode（office/code：额度闸门 + root 拒绝）
    if [ "$EXHAUSTED" = 1 ]; then
        warn '本周免费额度已用完，无法进入该会话。'
        show_upgrade_hint
        pause
        return 0
    fi
    [ "$LOW" = 1 ] && warn "本周额度已不足 10%（剩余 $BAL_REMAINING token），请合理安排使用。"
    if [ "$(id -u)" -eq 0 ]; then
        warn '办公/编码模式请在普通权限下运行（当前为 root）——退出后不带 sudo 重新运行即可。'
        pause
        return 0
    fi
    start_session "$1"
}

# ---------------- 版本输出 ----------------
printf '\n\033[36m===============================================\033[0m\n'
printf '\033[36m  AI 电脑维修U盘 · Linux 在线维修（场景③）\033[0m\n'
printf '\033[36m  启动器版本: %s\033[0m\n' "$SCRIPT_VERSION"
printf '\033[36m  官方发布页: https://tokeneff.com/usb\033[0m\n'
printf '\033[36m===============================================\033[0m\n'

# ---------------- 激活闸门 + 余额 ----------------
AUTH_KEY="$(read_auth_token)"
if [ -n "$AUTH_KEY" ]; then
    ok '已读取U盘凭证（auth_token）'
else
    do_activation || exit 1
fi
query_balance
if [ "$BAL_VERIFY_REQUIRED" = 1 ]; then
    email_verify || warn '未完成邮箱验证：维修会话可能受限（超阈值未验证的 key 将被网关降档）。可稍后在菜单中重新触发。'
fi

# ---------------- --repair 重入：直进维修会话，结束即退出（不回菜单） ----------------
if [ "$REPAIR_MODE" = 1 ]; then
    if [ "$EXHAUSTED" = 1 ]; then
        warn '本周免费额度已用完，无法进入维修会话。'
        show_upgrade_hint
        exit 1
    fi
    start_session repair
    exit 0
fi

# ---------------- 主菜单 ----------------
do_exit() {
    if [ "$RECORD_MODE" = "enterprise" ]; then
        printf '\n\033[33m[企业运维模式] 会话历史保留功能 Linux v0.1 未实现：\n本次会话历史位于 %s\n回车=随清理删除 / 输入 n=保留: \033[0m' "$WORK"
        local ans=''
        IFS= ask -r ans || ans=""
        case "${ans,,}" in
            n*) KEEP_WORK=1; printf '已选择保留（请自行记下上述路径）。\n' ;;
            *) WORK_CLEAN_CONFIRMED=1 ;;
        esac
    fi
    printf '\n\033[32m===============================================\033[0m\n'
    printf '\033[32m  感谢使用 AI 电脑维修U盘，再见！\033[0m\n'
    printf '\033[32m===============================================\033[0m\n'
    pause
    exit 0
}

while true; do
    printf '\n\033[36m---------------- 主菜单 ----------------\033[0m\n'
    printf '  [1] 只读诊断（收集信息 + 给出建议，不改系统）\n'
    printf '  [2] 维修会话（需管理员权限 root）\n'
    printf '  [3] 办公助手（写文档/表格/文案，免提权）\n'
    printf '  [4] 编码模式（软件开发/脚本，完全控制权限，免提权）\n'
    printf '  [5] 余额查询 / 管理账号\n'
    printf '  [0] 退出（清理本机临时文件）\n'
    choice=''
    IFS= ask -rp '请输入编号: ' choice || choice=0
    case "$choice" in
        1) start_session readonly ;;
        2) run_repair_session ;;
        3) session_gate office ;;
        4) session_gate code ;;
        5)
            query_balance
            printf '    有效期至: %s\n' "${BAL_EXPIRES:-?}"
            if [ "$BAL_VERIFY_REQUIRED" = 1 ]; then
                email_verify || true
            fi ;;
        0) do_exit ;;
        *) warn '输入无效，请输入 0-5 的编号。' ;;
    esac
done
