#!/usr/bin/env bash
# usb-v1.0.sh 版本: 1.7.5  (AI 电脑维修 U盘 一键制作器 · Linux 端)
# =====================================================================
# 创建日期: 2026-09-12
# 版本: 1.7.5（code-review 修复全清——①sh 补升级防误清守卫（无 Ventoy 卷标即中止，
#       与 ps1 同构）+双侧文案引导改回卷标；②fetch_verified 下载校验封装：毒缓存单轮
#       自愈对齐 ps1，可选组件 sha 失败不再被 die 打死降级分支；③usb_place_file/ps1
#       入口同盘 ai-part 暂存+原子改名（中断不留半截）；④agents.json CLAUDE_INSTALLED
#       挂盘上复核结果；⑤升级下载失败沿用盘上版不隐藏入口；⑥ver_mark 写失败容错）
# 1.7.4（便携运行时跳拷补漏：Node/OpenClaw/Pi 纳入 bin/*.ver 同版本跳过——
#       1.7.1 只做了 claude-win/claude-linux/portablegit/codex 四件，P-B 三件升级时
#       每次白解压+重拷（Node ~110MB、OpenClaw ~380MB、Pi ~90MB 盘写入）；双侧同名互认）
# 1.7.3（code-review 审计修复——①三处 pipefail 致命点：nonce 有界输入、umount
#       零挂载 || true、进度 PCT 兜底；②manifest 取 sha 失败改告警跳过不再打死制作；
#       ③小文件投放先暂存再落盘（失败不残留 U盘）+ .ps1 补 BOM；④邮箱 JSON 走安全
#       构造器；⑤便携 claude.exe 成功提示移入复核通过分支）
# 1.7.2（与 ps1 同版：补齐双侧投放对称缺口——ps1 此前不写 maker_version、不投放
#       repair-on-linux.sh；sh 侧两处本就具备，仅版本号对齐）
# 1.7.1（升级提速补全：便携运行时同版本跳拷——盘上 bin/*.ver 标记
#       （claude-win/claude-linux/portablegit/codex）与当前版本一致时跳过解压+重拷，
#       省数百 MB 盘写入；标记与 ps1 侧同名互认，规则同 ventoy_version）
# 1.7.0（升级提速：升级模式两项跳过——①盘上 Ventoy 版本标记与 manifest 一致时
#       跳过 Ventoy2Disk 刷引导（数据分区根 ventoy_version 标记，第 8 步写入）；
#       ②盘中同名镜像 sha256 与发布侧钉值一致时跳过整文件重写（Live ISO 1.5GB 大头）。
#       纯脚本层升级从 8~15 分钟压到 2~3 分钟）
# 1.6.0（升级直达：检测到成品U盘时三选一菜单默认「无损升级」，升级模式跳过
#       选盘/清盘确认/组件勾选问答，按盘上现状增量更新；settings.conf 存在即保留不覆盖；
#       修复结尾使用提示在 umount 后检查 $MNT 恒假的存量 bug）
# 1.5.0（环境自审）及更早见 git history
# 1.4.0（场景③Linux 投放/引擎/checksum 活 bug）及更早见 git history
# 状态: 草稿（Ventoy CLI 参数待 K0 实测后定稿，见 TODO(K0)）
# 设计依据: 技术方案_AI电脑维修U盘_总体设计_20260912.md §2.5.2 / §2.5.3
#
# 重要说明（§2.5.2 定稿决策）：Linux 端【不下载 Win10/Win11 ISO】。
# 原因：Fido 式微软官方直链解析为 PowerShell 实现，无 bash 等价物；
# Linux 用户制作完成后请手动从微软官网下载 ISO 拷入 U盘 ISO 目录：
#   https://www.microsoft.com/zh-cn/software-download/
#
# 用法（官网一键命令）:
#   curl -sL https://usb.tokeneff.com/maker/usb-v1.0.sh | sudo bash
# 审阅后再执行（推荐）:
#   curl -sLO https://usb.tokeneff.com/maker/usb-v1.0.sh && less usb-v1.0.sh && sudo bash usb-v1.0.sh
#   可选（P-A A4）: sudo bash usb-v1.0.sh --agents claude,codex,openclaw,pi,node,linux   # 跳过逐项问答，逗号分隔；
#   claude=便携 Claude Code / codex=Codex CLI / openclaw=OpenClaw / pi=Pi 编码 agent /
#   node=便携 Node（勾 openclaw/pi 时建议附带）/ linux=Debian 12 netinst；未列项视为不装
# =====================================================================
set -euo pipefail

# ---------------- 全局常量（集中定义） ----------------
SCRIPT_VERSION="1.7.5"
MANIFEST_URL="https://usb.tokeneff.com/maker/manifest.json"   # TODO(发布): 迁移到独立 CDN 域名（§2.5.4 故障隔离）
MIN_BASE_GB=5   # 选盘前基础门槛（P-A A4 两段预检之一）：Ventoy + 1.5GB 维修 ISO + /R:2048 保留 + 余量；勾选项在勾选后动态复查
HTTP_TIMEOUT=30
MAX_RETRY=3
PORTAL_API_BASE="https://tokeneff.com/api/usb"   # 制作时签发 USB token 的 portal 接口前缀（换域名改这里）
WORKDIR="$(mktemp -d /tmp/ai-repair-usb-maker.XXXXXX)"     # 一次性解压暂存（EXIT 清）
CACHE="${HOME}/.cache/ai-repair-usb-maker"                 # 1.3.7：下载缓存跨次保留（换盘重跑免重新下载）
NONCE_FILE=".ai-repair-maker-session"                      # 1.3.7：掉盘后找回同一只盘的标识（Ventoy 写完、数据分区挂载后才写）

# ---- TODO(K0): Ventoy CLI 实测参数对照表（K0 验证后替换为实测值）----
# Ventoy2Disk.sh CLI：-i 安装（清盘）/-u 升级（保留数据分区文件）/-l 查询是否已装；-g GPT；-r <MB> 盘尾保留
VENTOY_RESERVE_MB=2048

# ---------------- 输出工具 ----------------
c_step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
c_ok()   { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
c_warn() { printf '    \033[33m[警告] %s\033[0m\n' "$1"; }
c_fail() { printf '\n\033[31m[失败] %s\033[0m\n' "$1"; }
die() {
    c_fail "$1"
    [ -n "${2:-}" ] && printf '\033[33m建议: %s\033[0m\n' "$2"
    exit 1
}
trap 'c_fail "脚本异常退出（行 $LINENO）"; rm -rf "$WORKDIR"' ERR
trap 'rm -rf "$WORKDIR"' EXIT   # 1.3.7：只清一次性暂存；下载缓存（CACHE）刻意保留，trap 不得引用它

# ---------------- 0. 版本输出（供应链自检，§2.5.5-③） ----------------
cat <<EOF

===============================================
  AI 电脑维修 U盘 一键制作器 (Linux)
  脚本版本: ${SCRIPT_VERSION}
  官方发布页: https://tokeneff.com/usb
===============================================

提示: 本脚本首行注释亦含版本号，可与官网公布的 SHA256 / 变更日志核对。
注意: Linux 端不自动下载 Windows 镜像，制作完成后请手动从微软官网下载拷入 U盘 ISO 目录。
EOF

# ---------------- 1. root 自检 ----------------
[ "$(id -u)" -eq 0 ] || die "需要 root 权限。" "请使用: curl -sL https://usb.tokeneff.com/maker/usb-v1.0.sh | sudo bash"
c_ok "已获得 root 权限"

# ---------------- 1.5 环境自审：贴错命令 / 装错场景自动纠偏 ----------------
# ask()：curl|sudo bash 下 stdin 是脚本管道，裸 read 会把下一行脚本当答案并吞掉；
# bash 管道模式不设 fd255，exec 全局换栈有截断风险，故逐次交互按需绑定 /dev/tty。
ask() {
    if [ "${AI_REPAIR_ASK_STDIN:-0}" != 1 ] && [ ! -t 0 ] && builtin read "$@" < /dev/tty 2>/dev/null; then
        return 0
    fi
    builtin read "$@"
}
[ "$(uname -s)" = "Linux" ] || die "此命令是 Linux 制作器，不能在 $(uname -s) 上运行。" \
    "Windows 制盘: irm https://usb.tokeneff.com/maker/usb-v1.0.ps1 | iex（PowerShell）；Mac 无制盘端，请改用 Windows/Linux 电脑。"

audit_find_usbs() {   # 列出已挂载的本项目U盘数据分区根（无则空输出）
    local d p
    for d in /media/*/* /media/* /run/media/*/* /mnt/*; do
        [ -d "$d" ] || continue
        for p in .ai-repair-maker-session repair-on-windows.ps1 repair-on-linux.sh; do
            if [ -e "$d/$p" ]; then printf '%s\n' "$d"; break; fi
        done
    done | sort -u
}
LIVE_MARKER="${AI_REPAIR_LIVE_MARKER:-/usr/local/bin/welcome.sh}"
AUDIT_USBS="$(audit_find_usbs || true)"
if [ -f "$LIVE_MARKER" ] && [ "${AI_REPAIR_MAKER_FORCE:-0}" != "1" ]; then
    c_fail "这里是「AI 维修 Live 系统」——本机是正在维修的电脑，不需要制作 U盘。"
    printf '开始维修请运行 U盘 上的启动器:\n'
    _u="$(printf '%s' "$AUDIT_USBS" | head -n1)"
    if [ -n "$_u" ]; then
        printf '    bash "%s/repair-on-linux.sh"\n' "$_u"
    else
        printf '    在文件管理器进入本项目的U盘，打开终端后运行: bash repair-on-linux.sh\n'
    fi
    printf '确需在此环境重做/升级 U盘（罕见）: 先下载本脚本，再 sudo AI_REPAIR_MAKER_FORCE=1 bash usb-v1.0.sh\n'
    exit 0
fi
UPGRADE_MODE=0; UPGRADE_ROOT=""
if [ -n "$AUDIT_USBS" ]; then
    mapfile -t _AUDIT_ROOTS <<<"$AUDIT_USBS"
    c_warn "检测到已制作的本项目U盘："
    printf '%s\n' "$AUDIT_USBS" | sed 's/^/      · /'
    cat <<'AUDIT_MENU'

    接下来想做什么？
      [1] 无损升级（推荐）—— 更新脚本/AI引擎/维修系统/Ventoy引导；凭证、配置、盘中文件全保留
      [2] 重新制作 —— 清空重做（走完整流程，含各组件重新勾选）
      [3] 退出 —— 我其实是想修电脑（Linux 在U盘上运行 bash repair-on-linux.sh；Windows 双击 repair-on-windows.bat）
AUDIT_MENU
    _CHOICE=""
    ask -rp '请选择（直接回车 = 1 无损升级）: ' _CHOICE || true
    case "${_CHOICE:-1}" in
        1)
            UPGRADE_MODE=1
            if [ "${#_AUDIT_ROOTS[@]}" -gt 1 ]; then
                i=1
                for r in "${_AUDIT_ROOTS[@]}"; do printf '      [%d] %s\n' "$i" "$r"; i=$((i+1)); done
                _SEL=""
                ask -rp "要升级哪一只？（输入编号 1-${#_AUDIT_ROOTS[@]}）: " _SEL || true
                [[ "$_SEL" =~ ^[0-9]+$ ]] && [ "$_SEL" -ge 1 ] && [ "$_SEL" -le "${#_AUDIT_ROOTS[@]}" ] \
                    || die "输入的编号无效。" "请重新运行本命令并输入列表中的编号。"
                UPGRADE_ROOT="${_AUDIT_ROOTS[$((_SEL-1))]}"
            else
                UPGRADE_ROOT="${_AUDIT_ROOTS[0]}"
            fi
            c_ok "进入无损升级模式（目标: ${UPGRADE_ROOT}）——盘中文件、凭证、配置全保留"
            ;;
        2)
            c_ok "进入重新制作流程（U盘将被清空，请注意备份）"
            ;;
        3)
            die "已退出制作器。" "要修电脑请运行U盘启动器：Linux bash repair-on-linux.sh；Windows 双击 repair-on-windows.bat。"
            ;;
        *)
            die "无效选择：${_CHOICE}（可选 1/2/3）。" "请重新运行本命令。"
            ;;
    esac
fi

# ---------------- 2. 依赖检查 ----------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1" "请先安装: $2"; }
need_cmd curl "sudo apt install curl / sudo dnf install curl"
need_cmd lsblk "sudo apt install util-linux"
need_cmd sha256sum "coreutils"
need_cmd unzip "sudo apt install unzip / sudo dnf install unzip"
if command -v sgdisk >/dev/null 2>&1; then
    PART_TOOL="sgdisk"
elif command -v fdisk >/dev/null 2>&1; then
    PART_TOOL="fdisk"
else
    die "缺少分区工具 sgdisk 或 fdisk。" "sudo apt install gdisk 或 util-linux"
fi
c_ok "依赖检查通过（分区工具: ${PART_TOOL}）"

# ---------------- 3. 拉取 manifest（带超时与重试） ----------------
c_step "正在获取组件清单 (manifest.json) ..."
fetch_retry() {  # $1=url $2=dest(- 则输出到 stdout)
    local url="$1" dest="${2:-}" i
    for i in $(seq 1 "$MAX_RETRY"); do
        if [ "$dest" = "-" ]; then
            curl -fsSL --max-time "$HTTP_TIMEOUT" "$url" && return 0
        else
            # curl -C - 在文件已下完时服务器回 416 → curl 报错 33；先比对远端实际大小，相等即视为完成
            local remote_size=""
            remote_size="$(curl -fsSL -I --max-time "$HTTP_TIMEOUT" "$url" \
                | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1)"
            if [ -n "$remote_size" ] && [ -f "$dest" ] && [ "$(stat -c%s "$dest")" = "$remote_size" ]; then
                return 0
            fi
            curl -fSL --max-time "$HTTP_TIMEOUT" -C - -o "$dest" "$url" && return 0
        fi
        c_warn "请求失败（第 ${i}/${MAX_RETRY} 次）: $url"
        sleep $((2 * i))
    done
    return 1
}
MANIFEST_JSON="$(fetch_retry "$MANIFEST_URL" "-")" \
    || die "无法下载组件清单。" "请检查网络连接后重试；若多次失败，请访问 https://tokeneff.com/usb 查看服务公告。"

# 解析 manifest：优先 jq，缺失时用 python3
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 \
    || die "缺少 JSON 解析工具 jq 或 python3。" "sudo apt install jq"
json_get() {  # $1=组件name $2=字段
    local name="$1" field="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg n "$name" --arg f "$field" '.components[] | select(.name==$n) | .[$f] // empty' <<<"$MANIFEST_JSON" | head -n1
    else
        python3 -c "
import json,sys
m=json.loads(sys.argv[3])
for c in m.get('components',[]):
    if c.get('name')==sys.argv[1]:
        print(c.get(sys.argv[2],'')); break
" "$name" "$field" "$MANIFEST_JSON"
    fi
}
if command -v jq >/dev/null 2>&1; then
    MANIFEST_VERSION="$(jq -r '.version // "unknown"' <<<"$MANIFEST_JSON")"
else
    MANIFEST_VERSION="$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('version','unknown'))" "$MANIFEST_JSON")"
fi
c_ok "组件清单获取成功（清单版本: ${MANIFEST_VERSION}）"

# ---------------- 3.5 下载缓存（1.3.7：跨次保留，换盘重跑免重新下载） ----------------
mkdir -p "$CACHE"
find "$CACHE" -type f -mtime +30 -delete 2>/dev/null || true   # 30 天未用的缓存条目清理
cache_hit() {  # $1=file $2=expected_sha(可空；空则按非空文件判) → 0=命中，跳过下载
    [ -s "$1" ] || return 1
    if [ -n "$2" ]; then
        local actual; actual="$(sha256sum "$1" | awk '{print $1}')"
        [ "${actual,,}" = "${2,,}" ] || return 1
    fi
    return 0
}

# ---------------- 4. 枚举 USB 磁盘（硬过滤） ----------------
c_step "正在检测已插入的 U盘 ..."
# 只列 TRAN=usb 的整块磁盘 —— 硬过滤系统盘/内置盘（§2.5.3-2）
mapfile -t USB_DISKS < <(lsblk -d -n -o NAME,TRAN | awk '$2=="usb"{print $1}')
[ "${#USB_DISKS[@]}" -gt 0 ] || die "未检测到 U盘。" "请插入容量 ≥${MIN_BASE_GB}GB 的 U盘 后重新运行。"

# 候选 = 容量 ≥基础门槛 的 USB 磁盘；小存储（读卡器/加密狗）提示后忽略
MIN_BYTES=$((MIN_BASE_GB * 1024 * 1024 * 1024))
CANDIDATES=()
for d in "${USB_DISKS[@]}"; do
    sz=$(lsblk -d -n -o SIZE -b "/dev/$d" 2>/dev/null || lsblk -d -n -o SIZE "/dev/$d" | head -n1)
    bytes=$(numfmt --from=auto "$sz" 2>/dev/null || echo 0)
    if [ "$bytes" -ge "$MIN_BYTES" ]; then
        CANDIDATES+=("$d")
    else
        model=$(lsblk -d -n -o MODEL "/dev/$d" | head -n1)
        echo "  已忽略 /dev/$d（${model:-未知型号}，容量不足 ${MIN_BASE_GB} GB，非制作目标）"
    fi
done
[ "${#CANDIDATES[@]}" -gt 0 ] || die "所有 USB 磁盘容量均不足 ${MIN_BASE_GB} GB。" "请更换容量 ≥${MIN_BASE_GB}GB（推荐 128GB）的 U盘 后重新运行。"

echo ""
usb_size() { lsblk -d -n -o SIZE,MODEL "/dev/$1" | head -n1; }
if [ "$UPGRADE_MODE" = "1" ]; then
    # 升级模式：目标盘 = 检测到的数据分区所在物理盘（不再人工选盘，不清盘）
    _UPART="$(findmnt -no SOURCE "$UPGRADE_ROOT" 2>/dev/null | head -n1)"
    _UDISK="${_UPART%%[0-9]*}"   # /dev/sdb1 → /dev/sdb
    case "$_UDISK" in
        /dev/sd[a-z]|/dev/sd[a-z][a-z]) ;;
        *) die "无法定位 ${UPGRADE_ROOT} 对应的U盘设备（${_UPART:-未挂载}）。" "请重新插好U盘后重试；若反复失败，请重新运行并选「重新制作」。" ;;
    esac
    TARGET_NAME="${_UDISK#/dev/}"
    _FOUND=0
    for d in "${CANDIDATES[@]}"; do [ "$d" = "$TARGET_NAME" ] && { _FOUND=1; break; }; done
    [ "$_FOUND" = "1" ] || die "升级目标 /dev/$TARGET_NAME 不在本次检测到的U盘列表中。" "请重新插好U盘后重试。"
    read -r size model < <(usb_size "$TARGET_NAME")
    c_ok "升级目标已锁定: /dev/$TARGET_NAME  |  ${model:-未知型号}  |  ${size:-未知容量}（${UPGRADE_ROOT} 所在的U盘）"
elif [ "${#CANDIDATES[@]}" -eq 1 ]; then
    # 唯一合格 U盘 → 自动选中（防误写由下方整盘清空 YES 确认兜底）
    TARGET_NAME="${CANDIDATES[0]}"
    read -r size model < <(usb_size "$TARGET_NAME")
    echo "检测到唯一合格 U盘，已自动选中：/dev/$TARGET_NAME  |  ${model:-未知型号}  |  ${size:-未知容量}"
else
    echo "检测到多只合格 U盘，请输入要制作的那只的编号："
    i=1
    for d in "${CANDIDATES[@]}"; do
        read -r size model < <(usb_size "$d")
        printf '  [%d] /dev/%s  |  %s  |  %s\n' "$i" "$d" "${model:-未知型号}" "${size:-未知容量}"
        i=$((i+1))
    done
    echo ""
    ask -rp "请输入要制作的 U盘 编号（1-${#CANDIDATES[@]}）: " SEL
    [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#CANDIDATES[@]}" ] \
        || die "输入的编号无效。" "请重新运行并输入列表中的编号。"
    TARGET_NAME="${CANDIDATES[$((SEL-1))]}"
fi
TARGET_DEV="/dev/${TARGET_NAME}"
SIZE_BYTES="$(lsblk -d -n -b -o SIZE "$TARGET_DEV" | head -n1 | tr -d ' ')"
SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
[ "$SIZE_GB" -ge "$MIN_BASE_GB" ] \
    || die "所选 U盘 容量约 ${SIZE_GB}GB，小于最低要求 ${MIN_BASE_GB}GB。" "请更换容量 ≥${MIN_BASE_GB}GB（推荐 128GB）的 U盘 后重新运行。"

# 1.7.5 防误清：成品盘识别只看入口文件（audit_find_usbs），手拷入口脚本到普通U盘会被误判为成品盘
# → 升级模式强制目标盘带 Ventoy 卷标（真成品盘恒有）；否则后续 Ventoy 探测失败会走 -i 整盘重建、
# 清掉用户数据——与 ps1 侧守卫同构（1.7.3 ④ 只修了单侧）
if [ "$UPGRADE_MODE" = "1" ] && ! lsblk -n -o LABEL "$TARGET_DEV" | grep -qx 'Ventoy'; then
    die "目标盘没有 Ventoy 卷，不是本项目成品U盘（可能只是拷入了入口脚本）。" \
        "为防误清数据已中止。若确为本项目成品盘且改过卷标，请将数据分区卷标改回 Ventoy 后重试；若确实要重新制作此盘，请重新运行并选「重新制作」。"
fi

# ---------------- 4.5 --agents 参数解析（P-A A4：参数优先，缺省逐项问答） ----------------
AGENTS_ARG=""
for ((ai=1; ai<=$#; ai++)); do
    a="${!ai}"
    if [ "$a" = "--agents" ]; then
        an=$((ai+1)); AGENTS_ARG="${!an:-}"
        [ -n "$AGENTS_ARG" ] || die "--agents 需要参数（如 --agents claude,codex,linux）。" ""
    elif [[ "$a" == --agents=* ]]; then
        AGENTS_ARG="${a#--agents=}"
    fi
done
case "$AGENTS_ARG" in *[^a-z,]*)
    die "--agents 参数含非法字符（只接受逗号分隔的 claude/codex/openclaw/pi/node/linux）。" "" ;;
esac

# ---------------- 5. 毁盘警告 + YES 确认（升级模式 → 绿色无损升级确认） ----------------
echo ""
if [ "$UPGRADE_MODE" = "1" ]; then
    printf '\033[32m================================================\033[0m\n'
    printf '\033[32m  无损升级: %s （约 %dGB）\033[0m\n' "$TARGET_DEV" "$SIZE_GB"
    printf '\033[32m  盘中文件、凭证、配置全部保留；仅更新脚本/引擎/镜像版本。\033[0m\n'
    printf '\033[32m================================================\033[0m\n'
    ask -rp '回车开始升级（Ctrl+C 取消）: ' _UGO || true
else
    printf '\033[31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
    printf '\033[31m  严重警告：制作过程将清空该 U盘 上的全部数据！\033[0m\n'
    printf '\033[31m  目标: %s （约 %dGB）\033[0m\n' "$TARGET_DEV" "$SIZE_GB"
    printf '\033[31m  该操作不可恢复，请先备份 U盘 中的重要文件。\033[0m\n'
    printf '\033[31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
    ask -rp "确认继续请输入大写 YES: " CONFIRM
    [ "$CONFIRM" = "YES" ] || { echo "已取消，未对 U盘 做任何修改。"; exit 0; }
fi

# ---------------- 5.5 Agent / Linux 镜像勾选（P-A A4）+ 容量动态复查 ----------------
# Codex 可用性由 manifest 驱动：清单含 codex 组件（url 非空）才可选；否则提示跳过且 agents.json 不记 codex 条目
CODEX_URL="$(json_get codex url)"
CODEX_FNAME="$(json_get codex filename)"
CODEX_SHA="$(json_get codex sha256)"
CODEX_VER="$(json_get codex version)"
CODEX_AVAILABLE=0; [ -n "$CODEX_URL" ] && CODEX_AVAILABLE=1
[ "$CODEX_AVAILABLE" = "1" ] || c_warn "Codex CLI 暂不可用（发布清单未提供），本次制作已跳过，不影响其他组件。"

# P-B：OpenClaw / Pi / 便携 Node 可用性同样由 manifest 驱动（Node 仅作 [3]/[4] 的运行时，不单列勾选项）
OC_URL="$(json_get openclaw url)";   OC_FNAME="$(json_get openclaw filename)";   OC_SHA="$(json_get openclaw sha256)";   OC_VER="$(json_get openclaw version)"
PI_URL="$(json_get pi url)";         PI_FNAME="$(json_get pi filename)";         PI_SHA="$(json_get pi sha256)";         PI_VER="$(json_get pi version)"
NODE_URL="$(json_get node url)";     NODE_FNAME="$(json_get node filename)";     NODE_SHA="$(json_get node sha256)";     NODE_VER="$(json_get node version)"
OC_AVAILABLE=0;   [ -n "$OC_URL" ]   && OC_AVAILABLE=1
PI_AVAILABLE=0;   [ -n "$PI_URL" ]   && PI_AVAILABLE=1
NODE_AVAILABLE=0; [ -n "$NODE_URL" ] && NODE_AVAILABLE=1
[ "$OC_AVAILABLE" = "1" ]   || c_warn "OpenClaw 暂不可用（发布清单未提供），已跳过。"
[ "$PI_AVAILABLE" = "1" ]   || c_warn "Pi 暂不可用（发布清单未提供），已跳过。"
if [ "$((OC_AVAILABLE + PI_AVAILABLE))" -gt 0 ] && [ "$NODE_AVAILABLE" = "0" ]; then
    c_warn "便携 Node 运行时未提供，OpenClaw/Pi 将无法运行（如需使用请等待发布更新）。"
fi

DEBIAN_NAME="debian-12.8.0-amd64-netinst.iso"
DEBIAN_URL="https://cdimage.debian.org/cdimage/archive/12.8.0/amd64/iso-cd/debian-12.8.0-amd64-netinst.iso"
DEBIAN_SHA="04396d12b0f377958a070c38a923c227832fa3b3e18ddc013936ecf492e9fbb3"
DEBIAN_GB=1     # ~650MB，取整 1GB 余量
CODEX_GB=1      # ~334MB，取整 1GB 余量
OC_GB=1         # ~154MB 下载 / ~380MB 落盘，取整 1GB 余量
PI_GB=1         # ~33MB 下载 / ~90MB 落盘，取整 1GB 余量
NODE_GB=1       # ~36MB zip / ~110MB 落盘，取整 1GB 余量

if [ "$UPGRADE_MODE" = "1" ] && [ -z "$AGENTS_ARG" ]; then
    # 升级模式：勾选沿用盘上现状（Claude 为核心引擎始终更新；改选请走「重新制作」）
    WANT_CLAUDE=1
    WANT_CODEX=0;    [ "$CODEX_AVAILABLE" = "1" ] && [ -f "$UPGRADE_ROOT/bin/codex.exe" ] && WANT_CODEX=1
    WANT_OPENCLAW=0; [ "$OC_AVAILABLE" = "1" ]   && [ -d "$UPGRADE_ROOT/bin/openclaw" ]  && WANT_OPENCLAW=1
    WANT_PI=0;       [ "$PI_AVAILABLE" = "1" ]   && [ -d "$UPGRADE_ROOT/bin/pi" ]        && WANT_PI=1
    WANT_NODE=0;     [ "$NODE_AVAILABLE" = "1" ] && [ -d "$UPGRADE_ROOT/bin/node" ]      && WANT_NODE=1
    WANT_DEBIAN=0;   [ -f "$UPGRADE_ROOT/ISO/${DEBIAN_NAME}" ] && WANT_DEBIAN=1
    c_ok "升级沿用盘上勾选: Claude=$( [ $WANT_CLAUDE = 1 ] && echo 装 || echo 不装 ) / Codex=$( [ $WANT_CODEX = 1 ] && echo 装 || echo 不装 ) / OpenClaw=$( [ $WANT_OPENCLAW = 1 ] && echo 装 || echo 不装 ) / Pi=$( [ $WANT_PI = 1 ] && echo 装 || echo 不装 ) / Node=$( [ $WANT_NODE = 1 ] && echo 装 || echo 不装 ) / Debian=$( [ $WANT_DEBIAN = 1 ] && echo 装 || echo 不装 )"
elif [ -n "$AGENTS_ARG" ]; then
    # --agents 参数优先：逗号分隔，未列项视为不装；不可用项忽略并提示
    WANT_CLAUDE=0; WANT_CODEX=0; WANT_OPENCLAW=0; WANT_PI=0; WANT_NODE=0; WANT_DEBIAN=0
    case ",$AGENTS_ARG," in *",claude,"*)   WANT_CLAUDE=1 ;; esac
    case ",$AGENTS_ARG," in *",codex,"*)    WANT_CODEX=1 ;; esac
    case ",$AGENTS_ARG," in *",openclaw,"*) WANT_OPENCLAW=1 ;; esac
    case ",$AGENTS_ARG," in *",pi,"*)       WANT_PI=1 ;; esac
    case ",$AGENTS_ARG," in *",node,"*)     WANT_NODE=1 ;; esac
    case ",$AGENTS_ARG," in *",linux,"*)    WANT_DEBIAN=1 ;; esac
    if [ "$WANT_CODEX" = "1" ] && [ "$CODEX_AVAILABLE" = "0" ]; then
        c_warn "--agents 含 codex 但当前不可用，已忽略该项。"
        WANT_CODEX=0
    fi
    if [ "$WANT_OPENCLAW" = "1" ] && [ "$OC_AVAILABLE" = "0" ]; then
        c_warn "--agents 含 openclaw 但当前不可用，已忽略该项。"; WANT_OPENCLAW=0
    fi
    if [ "$WANT_PI" = "1" ] && [ "$PI_AVAILABLE" = "0" ]; then
        c_warn "--agents 含 pi 但当前不可用，已忽略该项。"; WANT_PI=0
    fi
    # 与交互分支语义对齐：Node 运行时不可用时取消 OpenClaw/Pi（否则装了也起不来）
    if [ "$NODE_AVAILABLE" = "0" ] && { [ "$WANT_OPENCLAW" = "1" ] || [ "$WANT_PI" = "1" ]; }; then
        c_warn "便携 Node 运行时不可用，已取消 OpenClaw/Pi 勾选。"
        WANT_OPENCLAW=0; WANT_PI=0
    fi
    if [ "$WANT_OPENCLAW" = "1" ] || [ "$WANT_PI" = "1" ]; then
        # Node 运行时：勾了 openclaw/pi 但未显式勾 node → 自动附带（--agents 承诺全自动化，不再交互提问）
        if [ "$WANT_NODE" = "0" ] && [ "$NODE_AVAILABLE" = "1" ]; then
            WANT_NODE=1
            c_warn "已自动附带便携 Node 运行时（OpenClaw/Pi 依赖；--agents 未显式给出 node）。"
        fi
    fi
    c_ok "已按 --agents 勾选: Claude=$( [ $WANT_CLAUDE = 1 ] && echo 装 || echo 不装 ) / Codex=$( [ $WANT_CODEX = 1 ] && echo 装 || echo 不装 ) / OpenClaw=$( [ $WANT_OPENCLAW = 1 ] && echo 装 || echo 不装 ) / Pi=$( [ $WANT_PI = 1 ] && echo 装 || echo 不装 ) / Node=$( [ $WANT_NODE = 1 ] && echo 装 || echo 不装 ) / Debian=$( [ $WANT_DEBIAN = 1 ] && echo 装 || echo 不装 )"
else
    # 缺省逐项 y/n 问答；回车默认（claude 默认装，其余默认不装）
    ask -rp "安装便携 Claude Code（维修/办公 AI 引擎，约 236MB）？(Y/n): " R1
    [ "${R1,,}" = "n" ] && WANT_CLAUDE=0 || WANT_CLAUDE=1
    WANT_CODEX=0
    if [ "$CODEX_AVAILABLE" = "1" ]; then
        ask -rp "安装 Codex CLI（OpenAI 风格命令行助手，约 334MB）？(y/N): " R2
        [ "${R2,,}" = "y" ] && WANT_CODEX=1
    fi
    WANT_OPENCLAW=0; WANT_PI=0; WANT_NODE=0
    if [ "$OC_AVAILABLE" = "1" ]; then
        ask -rp "安装 OpenClaw（个人 AI 助理，约 380MB，需 Node 运行时）？(y/N): " R4
        [ "${R4,,}" = "y" ] && WANT_OPENCLAW=1
    fi
    if [ "$PI_AVAILABLE" = "1" ]; then
        ask -rp "安装 Pi（轻量编码 agent，约 90MB，需 Node 运行时）？(y/N): " R5
        [ "${R5,,}" = "y" ] && WANT_PI=1
    fi
    if [ "$WANT_OPENCLAW" = "1" ] || [ "$WANT_PI" = "1" ]; then
        if [ "$NODE_AVAILABLE" = "1" ]; then
            ask -rp "OpenClaw/Pi 需要 Node 运行时（约 110MB），一并安装？(Y/n): " RN
            case "${RN,,}" in n*) WANT_NODE=0 ;; *) WANT_NODE=1 ;; esac
        else
            c_warn "便携 Node 运行时不可用，OpenClaw/Pi 已取消勾选。"
            WANT_OPENCLAW=0; WANT_PI=0
        fi
    fi
    ask -rp "附带 Debian 12 netinst 安装镜像（约 650MB）？(y/N): " R3
    [ "${R3,,}" = "y" ] && WANT_DEBIAN=1 || WANT_DEBIAN=0
fi

# —— 容量动态复查（第二段）：MinBaseGB + Σ勾选项；不足时给出建议取消项（优先 Debian → codex）——
NEED_GB=$((MIN_BASE_GB))
[ "$WANT_CODEX" = "1" ] && NEED_GB=$((NEED_GB + CODEX_GB))
[ "$WANT_OPENCLAW" = "1" ] && NEED_GB=$((NEED_GB + OC_GB))
[ "$WANT_PI" = "1" ] && NEED_GB=$((NEED_GB + PI_GB))
[ "$WANT_NODE" = "1" ] && NEED_GB=$((NEED_GB + NODE_GB))
[ "$WANT_DEBIAN" = "1" ] && NEED_GB=$((NEED_GB + DEBIAN_GB))
# Windows 镜像需手动拷入（Linux 端不下载），此处不叠加 WinISO 体积
if [ "$NEED_GB" -gt "$SIZE_GB" ]; then
    c_warn "勾选后预计需要约 ${NEED_GB}GB，所选 U盘（约 ${SIZE_GB}GB）可能不足。建议取消（按优先级）："
    [ "$WANT_DEBIAN" = "1" ] && echo "    - 取消 Debian 12 镜像（省约 1GB）"
    [ "$WANT_OPENCLAW" = "1" ] && echo "    - 取消 OpenClaw（省约 1GB）"
    [ "$WANT_PI" = "1" ] && echo "    - 取消 Pi（省约 1GB）"
    [ "$WANT_CODEX" = "1" ] && echo "    - 取消 Codex CLI（省约 1GB）"
    ask -rp "输入 C 继续（空间不足风险自负）/ 其他任意键退出: " RC
    [ "${RC^^}" = "C" ] || { echo "已取消，未对 U盘 做任何修改。"; exit 0; }
fi

# ---------------- 6. 下载自产组件 + SHA256 校验 ----------------
c_step "开始下载组件（curl 断点续传；已下载过的组件自动命中缓存）..."
# 本机暂存空间预检（1.3.7 两段式：下载包 + 解压树 ≈ 下载体积×2 + 2GB 余量）
LOCAL_NEED_GB=2
[ "$WANT_CLAUDE" = "1" ] && LOCAL_NEED_GB=$((LOCAL_NEED_GB + 1))
[ "$WANT_CODEX" = "1" ] && LOCAL_NEED_GB=$((LOCAL_NEED_GB + CODEX_GB * 2))
[ "$WANT_OPENCLAW" = "1" ] && LOCAL_NEED_GB=$((LOCAL_NEED_GB + OC_GB * 2))
[ "$WANT_PI" = "1" ] && LOCAL_NEED_GB=$((LOCAL_NEED_GB + PI_GB * 2))
[ "$WANT_NODE" = "1" ] && LOCAL_NEED_GB=$((LOCAL_NEED_GB + NODE_GB * 2))
[ "$WANT_DEBIAN" = "1" ] && LOCAL_NEED_GB=$((LOCAL_NEED_GB + DEBIAN_GB))
CACHE_AVAIL_KB="$(df -Pk "$CACHE" | awk 'NR==2{print $4}')"
if [ "${CACHE_AVAIL_KB:-0}" -lt $((LOCAL_NEED_GB * 1024 * 1024)) ]; then
    die "本机磁盘空间不足：制作需约 ${LOCAL_NEED_GB}GB 暂存（${CACHE} 下载缓存 + 解压），当前仅剩 $((CACHE_AVAIL_KB / 1024 / 1024))GB。" "请清理磁盘后重试；缓存位于 ${CACHE}，30 天未用会自动清理。"
fi
c_ok "本机暂存空间检查通过（预计需要约 ${LOCAL_NEED_GB}GB）"
sha_check() {  # $1=file $2=expected $3=display
    [ -n "$2" ] || { c_warn "$3 未提供 SHA256，跳过校验（manifest 占位阶段）"; return 0; }
    local actual
    actual="$(sha256sum "$1" | awk '{print $1}')"
    [ "${actual,,}" = "${2,,}" ] \
        || { rm -f "$1"; die "$3 SHA256 校验失败！期望 $2，实际 $actual。已删除损坏文件，重跑制作器将重新完整下载。" "请重新运行；若反复失败请联系客服。"; }
    c_ok "$3 校验通过"
}

# 1.7.5：软校验 + 下载校验封装（与 ps1 Get-FileVerifiedViaBits 对齐）——
# 可选组件的 else 降级分支要求 sha 失败可返回，不能像 sha_check 那样 die 打死整轮
sha_check_soft() {  # $1=file $2=expected $3=display — 失败仅删坏文件返回 1，不 die
    [ -n "$2" ] || { c_warn "$3 未提供 SHA256，跳过校验（manifest 占位阶段）"; return 0; }
    local actual
    actual="$(sha256sum "$1" | awk '{print $1}')" || return 1
    [ "${actual,,}" = "${2,,}" ] && return 0
    rm -f "$1"
    return 1
}

fetch_verified() {  # $1=url $2=dest $3=sha $4=display — 下载+校验一体：
    # 校验失败（坏文件已删）后干净重下一次再复验；任一失败清半成品返回 1（调用点 c_warn 降级）。
    # 毒缓存成因：Range 续传把旧半截与新内容拼接——净重下不再续传即自愈
    if ! fetch_retry "$1" "$2"; then
        rm -f "$2"
        return 1
    fi
    sha_check_soft "$2" "$3" "$4" && return 0
    c_warn "$4 校验失败（坏文件已删），重新完整下载一次..."
    if ! fetch_retry "$1" "$2"; then
        rm -f "$2"
        return 1
    fi
    sha_check_soft "$2" "$3" "$4" || { rm -f "$2"; return 1; }
}

# 后台解压 + 心跳进度（1.3.1）：目标多为 exFAT U盘，几万小文件解压动辄十几分钟，
# 无进度会被当成假死。用法: extract_progress <标签> <目标目录> <命令...>（返回命令退出码）
extract_progress() {
    local label="$1" dest="$2"; shift 2
    "$@" &
    local pid=$! spin='-\|/' i=0 mb
    while kill -0 "$pid" 2>/dev/null; do
        mb="$(du -sm "$dest" 2>/dev/null | cut -f1)"
        printf '\r    [%s] %s 已写入 %sMB   ' "${spin:$((i++ % 4)):1}" "$label" "${mb:-0}"
        sleep 2
    done
    wait "$pid"
    local rc=$?
    printf '\r%*s\r' 50 ''
    return $rc
}
# Ventoy 官方直链（manifest url 为空时的兜底；Linux 端用 tar.gz 包）
VENTOY_VERSION="1.1.18"
VENTOY_ASSET="ventoy-${VENTOY_VERSION}-linux.tar.gz"
VENTOY_URL_BASE="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/${VENTOY_ASSET}"

# 场景③便携运行时（v0.2 决策）：Claude Code 官方 GCS 分发桶 + 自托管便携 Git（Bash 工具依赖）
CLAUDE_GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
PORTABLE_GIT_URL="https://usb.tokeneff.com/downloads/PortableGit-2.56.0.2-64-bit.zip"
PORTABLE_GIT_SHA="8e4cb757edb480c6e94ff3858352c2ea1e431cf5bc15d5df3fd56e2904c18dab"
PORTABLE_GIT_VERSION="2.56.0.2"   # 1.7.1：bin/portablegit.ver 跳拷标记比对值

declare -A LOCAL_FILE=()
declare -A LOCAL_SHA=()   # 1.7.0：各组件发布侧 sha256（ISO 跳拷判定用）
for name in ventoy-linux ai-repair-live winpe 'memtest86+'; do
    dl_key="$name"; [ "$name" = "ventoy-linux" ] && dl_key="ventoy"
    url="$(json_get "$name" url)"
    fname="$(json_get "$name" filename)"
    sha="$(json_get "$name" sha256)"
    if [ -z "$url" ] && [ "$name" = "ventoy-linux" ]; then
        # 动态解析官方直链：GitHub 直连优先，国内加速镜像兜底
        url="$VENTOY_URL_BASE"
        fname="$VENTOY_ASSET"; sha=""
        curl -fsIL --max-time 15 "$url" >/dev/null 2>&1 \
            || url="https://gh-proxy.com/$VENTOY_URL_BASE"
        echo "    Ventoy 直链解析成功（v${VENTOY_VERSION}）"
    elif [ -z "$url" ]; then
        # winpe / memtest86+ 尚未发布（P4.5 后填充）→ 跳过，不阻断制作
        c_warn "组件 ${name}（${fname}）尚未发布，本次制作跳过——不影响维修系统主体功能。"
        continue
    fi
    [ -n "$fname" ] || die "manifest 中组件 $name 缺少 filename。" ""
    dest="${CACHE}/${fname}"
    if cache_hit "$dest" "$sha"; then
        c_ok "缓存命中: ${fname}（跳过下载）"
    else
        echo "    下载 ${name} (${fname}) ..."
        fetch_retry "$url" "$dest" || die "组件 $name 下载失败。" "请检查网络后重新运行。"
        sha_check "$dest" "$sha" "$fname"
    fi
    LOCAL_FILE[$dl_key]="$dest"
    LOCAL_SHA[$dl_key]="${sha:-}"
done

# ---------------- 6.5 场景③便携运行时：claude.exe + MinGit（可选，失败不阻断） ----------------
# U盘 bin\ 内置后，任意 Windows 双击 repair-on-windows.bat 免安装直跑；
# 失败只警告：双击入口自动回落在线安装（方案 5.3 降级链不变）。
# P-A A4：按勾选裁剪——claude 仅勾选时下载；PortableGit 为 claude/codex 共用，任一勾选即安装
CLAUDE_EXE=""; CLAUDE_SHA=""; CLAUDE_OK=0   # 1.7.5：CLAUDE_OK=盘上 claude.exe 为本版复核通过/在位（agents.json 依据）
MINGIT_ZIP=""
mkdir -p "${CACHE}/portable-bin"
if [ "$WANT_CLAUDE" != "1" ]; then
    echo "    未勾选 Claude Code，跳过 claude.exe 下载。"
elif CLAUDE_VER="$(fetch_retry "${CLAUDE_GCS_BASE}/stable" - | tr -d '[:space:]')" && [ -n "$CLAUDE_VER" ]; then
    CLAUDE_MANIFEST="${CLAUDE_GCS_BASE}/${CLAUDE_VER}/manifest.json"
    # 1.4.0 修复活 bug：官方 manifest 实为多行 pretty-print，旧同行匹配模式恒输出空
    # → CLAUDE_SHA 空 → 便携 claude.exe 从 1.2.x 起被静默永久跳过。改块内范围模式。
    # 1.7.3：|| CLAUDE_SHA="" 防 pipefail 误杀——fetch_retry 3 次失败时裸赋值会让 set -e
    # 打死整轮制作（manifest 单独失败本应走下方 [ -z ] 告警跳过，不阻断）
    CLAUDE_SHA="$(fetch_retry "$CLAUDE_MANIFEST" - | sed -n '/"win32-x64":/,/}/s/.*"checksum": "\([0-9a-f]*\)".*/\1/p' | head -n1)" || CLAUDE_SHA=""
    if [ -z "$CLAUDE_SHA" ]; then
        c_warn "无法从官方 manifest 取得 win32-x64 checksum，跳过便携版 claude.exe（不阻断制作）。"
    elif cache_hit "${CACHE}/portable-bin/claude.exe" "$CLAUDE_SHA"; then
        CLAUDE_EXE="${CACHE}/portable-bin/claude.exe"
        c_ok "缓存命中: claude.exe（跳过下载，官方 sha256 校验通过）"
    elif fetch_verified "${CLAUDE_GCS_BASE}/${CLAUDE_VER}/win32-x64/claude.exe" "${CACHE}/portable-bin/TempClaude.exe" "$CLAUDE_SHA" "claude.exe"; then
        mv "${CACHE}/portable-bin/TempClaude.exe" "${CACHE}/portable-bin/claude.exe"
        CLAUDE_EXE="${CACHE}/portable-bin/claude.exe"
        c_ok "便携版 claude.exe 就绪（${CLAUDE_VER}，官方 sha256 校验通过）"
    else
        c_warn "便携版 claude.exe 获取失败（下载/校验）。不阻断制作——场景③双击入口将回落为在线安装。"
    fi
else
    c_warn "Claude Code 官方分发桶不可达，跳过便携版 claude.exe（不阻断制作）。"
fi
# 场景③ Linux 便携引擎（repair-on-linux.sh 便携优先链第一环；同一 WANT_CLAUDE 勾选，失败不阻断）
# linux-x64 资产为裸 ELF 单文件 claude（~294MB），非 zip 包
CLAUDE_LINUX=""; CLAUDE_LINUX_SHA=""
if [ "$WANT_CLAUDE" != "1" ]; then
    echo "    未勾选 Claude Code，跳过 claude-linux 下载。"
elif [ -z "${CLAUDE_VER:-}" ] || [ -z "${CLAUDE_MANIFEST:-}" ]; then
    c_warn "官方分发桶不可达（上步已警告），跳过 claude-linux 下载（不阻断制作）——Linux 启动器将回落本机/在线。"
else
    CLAUDE_LINUX_SHA="$(fetch_retry "$CLAUDE_MANIFEST" - | sed -n '/"linux-x64":/,/}/s/.*"checksum": "\([0-9a-f]*\)".*/\1/p' | head -n1)" || CLAUDE_LINUX_SHA=""   # 1.7.3 同上：防 pipefail 误杀
    if [ -z "$CLAUDE_LINUX_SHA" ]; then
        c_warn "无法从官方 manifest 取得 linux-x64 checksum，跳过便携 claude-linux（不阻断制作）。"
    elif cache_hit "${CACHE}/portable-bin/claude-linux" "$CLAUDE_LINUX_SHA"; then
        CLAUDE_LINUX="${CACHE}/portable-bin/claude-linux"
        c_ok "缓存命中: claude-linux（跳过下载，官方 sha256 校验通过）"
    elif fetch_verified "${CLAUDE_GCS_BASE}/${CLAUDE_VER}/linux-x64/claude" "${CACHE}/portable-bin/TempClaudeLinux" "$CLAUDE_LINUX_SHA" "claude-linux"; then
        mv "${CACHE}/portable-bin/TempClaudeLinux" "${CACHE}/portable-bin/claude-linux"
        CLAUDE_LINUX="${CACHE}/portable-bin/claude-linux"
        c_ok "便携版 claude-linux 就绪（${CLAUDE_VER}，官方 sha256 校验通过）"
    else
        c_warn "便携版 claude-linux 获取失败（下载/校验）。不阻断制作——Linux 启动器将回落本机/在线。"
    fi
fi
if [ "$WANT_CLAUDE" = "1" ] || [ "$WANT_CODEX" = "1" ]; then
    if cache_hit "${CACHE}/portable-bin/PortableGit.zip" "$PORTABLE_GIT_SHA"; then
        MINGIT_ZIP="${CACHE}/portable-bin/PortableGit.zip"
        c_ok "缓存命中: PortableGit.zip（跳过下载，自托管 sha256 校验通过）"
    else
        echo "    便携 Git（Bash 工具依赖，约 154MB）..."
        if fetch_verified "$PORTABLE_GIT_URL" "${CACHE}/portable-bin/TempPortableGit.zip" "$PORTABLE_GIT_SHA" "PortableGit.zip"; then
            mv "${CACHE}/portable-bin/TempPortableGit.zip" "${CACHE}/portable-bin/PortableGit.zip"
            MINGIT_ZIP="${CACHE}/portable-bin/PortableGit.zip"
            c_ok "便携 Git 就绪（2.56.0.2，自托管 sha256 校验通过）"
        else
            c_warn "便携 Git 获取失败（下载/校验）。不阻断制作——目标电脑已装 Git 时不受影响，未装则 Bash 工具受限。"
        fi
    fi
else
    echo "    未勾选任何 AI 引擎，跳过便携 Git 下载。"
fi

# ---------------- 6.6 Codex CLI（P-A A4：勾选了 codex 才走；失败降级 installed=false） ----------------
CODEX_EXE=""
if [ "$WANT_CODEX" = "1" ] && [ "$CODEX_AVAILABLE" = "1" ]; then
    if cache_hit "${CACHE}/${CODEX_FNAME}" "$CODEX_SHA"; then
        CODEX_EXE="${CACHE}/${CODEX_FNAME}"
        c_ok "缓存命中: ${CODEX_FNAME}（跳过下载，发布侧 sha256 校验通过）"
    else
        echo "    Codex CLI（${CODEX_FNAME}，约 334MB）..."
        if fetch_verified "$CODEX_URL" "${CACHE}/codex-download.exe" "$CODEX_SHA" "$CODEX_FNAME"; then
            mv "${CACHE}/codex-download.exe" "${CACHE}/${CODEX_FNAME}"
            CODEX_EXE="${CACHE}/${CODEX_FNAME}"
            c_ok "Codex CLI 就绪（发布侧 sha256 校验通过）"
        else
            rm -f "${CACHE}/codex-download.exe"
            c_warn "Codex CLI 下载/校验失败。不阻断制作——盘上将不装 Codex，启动器不显示其入口。"
        fi
    fi
fi

# ---------------- 6.7 Debian 12 netinst（P-A A4：勾选了 Debian 才走；官方直链 + 官方钉值） ----------------
DEBIAN_ISO=""
if [ "$WANT_DEBIAN" = "1" ]; then
    if cache_hit "${CACHE}/${DEBIAN_NAME}" "$DEBIAN_SHA"; then
        DEBIAN_ISO="${CACHE}/${DEBIAN_NAME}"
        c_ok "缓存命中: ${DEBIAN_NAME}（跳过下载，官方 SHA256SUMS 钉值校验通过）"
    else
        echo "    Debian 12 netinst（${DEBIAN_NAME}，官方 cdimage 存档直链，约 650MB）..."
        if fetch_verified "$DEBIAN_URL" "${CACHE}/${DEBIAN_NAME}" "$DEBIAN_SHA" "$DEBIAN_NAME"; then
            DEBIAN_ISO="${CACHE}/${DEBIAN_NAME}"
            c_ok "Debian 12 netinst 就绪（官方 SHA256SUMS 钉值校验通过）"
        else
            c_warn "Debian 12 镜像下载/校验失败。不阻断制作——盘上将无 Linux 安装镜像。"
        fi
    fi
fi

# ---------------- 6.8 OpenClaw / Pi / 便携 Node（P-B：勾选了才走；失败降级 installed=false） ----------------
NODE_TAR=""; OC_TAR=""; PI_TAR=""
if [ "$WANT_NODE" = "1" ] && [ "$NODE_AVAILABLE" = "1" ]; then
    if cache_hit "${CACHE}/${NODE_FNAME}" "$NODE_SHA"; then
        NODE_TAR="${CACHE}/${NODE_FNAME}"
        c_ok "缓存命中: ${NODE_FNAME}（跳过下载，官方 SHASUMS 钉值校验通过）"
    else
        echo "    便携 Node ${NODE_VER}（${NODE_FNAME}，约 36MB zip）..."
        if fetch_verified "$NODE_URL" "${CACHE}/${NODE_FNAME}" "$NODE_SHA" "$NODE_FNAME"; then
            NODE_TAR="${CACHE}/${NODE_FNAME}"
            c_ok "便携 Node 运行时就绪（官方 SHASUMS 钉值校验通过）"
        else
            c_warn "便携 Node 下载/校验失败。OpenClaw/Pi 将无法运行，不阻断制作。"
        fi
    fi
fi
if [ "$WANT_OPENCLAW" = "1" ] && [ "$OC_AVAILABLE" = "1" ]; then
    if cache_hit "${CACHE}/${OC_FNAME}" "$OC_SHA"; then
        OC_TAR="${CACHE}/${OC_FNAME}"
        c_ok "缓存命中: ${OC_FNAME}（跳过下载，发布侧 sha256 校验通过）"
    else
        echo "    OpenClaw ${OC_VER} 预装包（${OC_FNAME}，约 154MB tar.gz）..."
        if fetch_verified "$OC_URL" "${CACHE}/${OC_FNAME}" "$OC_SHA" "$OC_FNAME"; then
            OC_TAR="${CACHE}/${OC_FNAME}"
            c_ok "OpenClaw 预装包就绪（发布侧 sha256 校验通过）"
        else
            c_warn "OpenClaw 下载/校验失败。不阻断制作——启动器不显示其入口。"
        fi
    fi
fi
if [ "$WANT_PI" = "1" ] && [ "$PI_AVAILABLE" = "1" ]; then
    if cache_hit "${CACHE}/${PI_FNAME}" "$PI_SHA"; then
        PI_TAR="${CACHE}/${PI_FNAME}"
        c_ok "缓存命中: ${PI_FNAME}（跳过下载，发布侧 sha256 校验通过）"
    else
        echo "    Pi ${PI_VER} 预装包（${PI_FNAME}，约 33MB tar.gz）..."
        if fetch_verified "$PI_URL" "${CACHE}/${PI_FNAME}" "$PI_SHA" "$PI_FNAME"; then
            PI_TAR="${CACHE}/${PI_FNAME}"
            c_ok "Pi 预装包就绪（发布侧 sha256 校验通过）"
        else
            c_warn "Pi 下载/校验失败。不阻断制作——启动器不显示其入口。"
        fi
    fi
fi

# ---------------- 7. Ventoy 无人值守写入 ----------------
c_step "正在将 Ventoy 引导层写入 U盘（此步骤将重建分区）..."
VENTOY_DIR="${WORKDIR}/ventoy-extracted"
mkdir -p "$VENTOY_DIR"
case "${LOCAL_FILE[ventoy]}" in
    *.tar.gz|*.tgz) tar -xzf "${LOCAL_FILE[ventoy]}" -C "$VENTOY_DIR" ;;
    *.zip)          unzip -qo "${LOCAL_FILE[ventoy]}" -d "$VENTOY_DIR" ;;
    *)              die "未知 Ventoy 包格式: ${LOCAL_FILE[ventoy]}" "" ;;
esac
VENTOY_SH="$(find "$VENTOY_DIR" -name 'Ventoy2Disk.sh' | head -n1)"
[ -n "$VENTOY_SH" ] || die "Ventoy 包内未找到 Ventoy2Disk.sh。" "manifest 指向的 Ventoy 包可能损坏，请联系客服。"
# 1.7.0 升级提速①：盘上引导层版本标记 = 本版 → 跳过 Ventoy2Disk 写入（省 1~3 分钟）
# 标记在数据分区根 ventoy_version（第 8 步挂载后写入）；读不到（≤1.6.x 旧盘/只读挂载失败）→ 照常写入
VENTOY_SKIP=0
if [ "${UPGRADE_MODE:-0}" = "1" ] && bash "$VENTOY_SH" -l "$TARGET_DEV" >/dev/null 2>&1; then
    _PROBE_MNT="${WORKDIR}/probe-ventoy"; mkdir -p "$_PROBE_MNT"
    _PROBE_PART="$(lsblk -n -b -o NAME,SIZE "$TARGET_DEV" | tail -n +2 | sort -k2 -n | tail -n1 | awk '{print $1}')"
    if [ -n "$_PROBE_PART" ] && mount -o ro "/dev/${_PROBE_PART}" "$_PROBE_MNT" 2>/dev/null; then
        [ "$(tr -d '[:space:]' < "${_PROBE_MNT}/ventoy_version" 2>/dev/null)" = "$VENTOY_VERSION" ] && VENTOY_SKIP=1
        umount "$_PROBE_MNT" 2>/dev/null || umount -l "$_PROBE_MNT" 2>/dev/null || true
    fi
fi
# 卸载目标盘上所有已挂载分区，避免写入冲突
# 零挂载分区时 grep 无匹配退 1 → pipefail 会误杀，|| true 兜底（umount 自身失败已在循环内兜底）
lsblk -n -o MOUNTPOINT "$TARGET_DEV" | grep -v '^$' | while read -r mp; do umount "$mp" || true; done || true
if [ "$VENTOY_SKIP" = "1" ]; then
    c_ok "盘上 Ventoy 引导层已是 v${VENTOY_VERSION}（版本一致，跳过刷写）"
else
# 已装 Ventoy → -u 无损升级（数据分区文件与 ISO 全部保留）；未装 → -i 全新安装（GPT + 盘尾保留）
if bash "$VENTOY_SH" -l "$TARGET_DEV" >/dev/null 2>&1; then
    c_warn "检测到 U盘已安装 Ventoy → 执行无损升级（盘中已有文件与 ISO 将全部保留）"
    VENTOY_ARGS="-u"
else
    VENTOY_ARGS="-i -g -r ${VENTOY_RESERVE_MB}"
fi
# 写入引导层：后台执行 + 从日志实时提取百分比（Ventoy2Disk.sh 将进度输出到 stdout）
echo "    执行: Ventoy2Disk.sh $VENTOY_ARGS $TARGET_DEV"
( bash "$VENTOY_SH" $VENTOY_ARGS "$TARGET_DEV" ) >"${WORKDIR}/ventoy-cli.log" 2>&1 &
V_PID=$!
ELAPSED=0; PCT=0
while kill -0 "$V_PID" 2>/dev/null; do
    sleep 1; ELAPSED=$((ELAPSED + 1))
    # 首轮日志尚无 % 行时 grep 退 1 → pipefail 会误杀，|| PCT=0 兜底（下方空值守卫保留）
    PCT=$(grep -o '[0-9]\{1,3\}%' "${WORKDIR}/ventoy-cli.log" 2>/dev/null | tail -n1 | tr -d '%') || PCT=0
    [ -n "$PCT" ] || PCT=0
    FILL=$((PCT / 4)); [ "$FILL" -gt 25 ] && FILL=25
    BAR=$(printf '%*s' "$FILL" '' | tr ' ' '#')$(printf '%*s' $((25 - FILL)) '' | tr ' ' '.')
    printf '\r    [%s] %3d%%  已用时 %02d分%02d秒 ' "$BAR" "$PCT" $((ELAPSED / 60)) $((ELAPSED % 60))
done
echo ""
wait "$V_PID" \
    || { tail -n 20 "${WORKDIR}/ventoy-cli.log" >&2
         die "Ventoy 写入失败。" "请重新插拔 U盘后重试；若反复失败请换一只 U盘。"; }
c_ok "Ventoy 引导层写入完成"
fi

# ---------------- 8. 挂载数据分区，拷入 ISO / ventoy.json / config 骨架 ----------------
c_step "正在拷入系统镜像与配置 ..."
sleep 3
partprobe "$TARGET_DEV" 2>/dev/null || blockdev --rereadpt "$TARGET_DEV" 2>/dev/null || true
sleep 2
# Ventoy 数据分区为最大分区（exFAT）
DATA_PART="$(lsblk -n -b -o NAME,SIZE "$TARGET_DEV" | tail -n +2 | sort -k2 -n | tail -n1 | awk '{print $1}')"
[ -n "$DATA_PART" ] || die "未找到 U盘 数据分区。" "Ventoy 写入异常，请重新运行。"
MNT="${WORKDIR}/mnt"
mkdir -p "$MNT"
mount "/dev/${DATA_PART}" "$MNT" || die "数据分区挂载失败。" "请检查系统是否安装 exfat 支持（exfatprogs / exfat-fuse）。"

# ---------------- 8.1 掉盘感知与恢复（1.3.7） ----------------
# 挂载态检测：不能用目录存在性判断 —— MNT 是 WORKDIR 下的挂载点目录，掉盘后空目录仍在，恒真
usb_alive() { mountpoint -q "$MNT"; }

wait_usb_return() {
    c_warn "U盘 在写入过程中断开了。请不要关闭本窗口、也不要重新运行制作器："
    echo  "  请把同一只 U盘 重新插好（可以换一个 USB 口），然后回到本窗口按回车。"
    echo  "  已下载的组件与已写入的部分都会自动保留，从断点继续。"
    # 清陈旧挂载：设备已消失时普通 umount 可能 EBUSY/挂起 → lazy 兜底
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    local nonce=""
    [ -s "${CACHE}/session-nonce" ] && nonce="$(cat "${CACHE}/session-nonce")"
    local probe="${WORKDIR}/probe" part p
    while true; do
        ask -rp "插好 U盘 后按回车继续: " _ACK
        mkdir -p "$probe"
        # nonce 重定位：候选 = 所有 USB 磁盘的分区；逐个临时挂到 probe 点读 nonce，
        # 匹配者挂回同一 $MNT 路径（路径不变 → 后续代码零改动），其余立即卸载
        for part in $(lsblk -d -n -o NAME,TRAN | awk '$2=="usb"{print $1}'); do
            for p in $(lsblk -n -o NAME "/dev/${part}" 2>/dev/null | tail -n +2); do
                if mount "/dev/${p}" "$probe" 2>/dev/null; then
                    if [ -n "$nonce" ] && [ "$(cat "$probe/$NONCE_FILE" 2>/dev/null)" = "$nonce" ]; then
                        umount "$probe"
                        mount "/dev/${p}" "$MNT" \
                            || die "找回的分区（/dev/${p}）重新挂载失败。" "请重新运行制作器——下载缓存已保留（${CACHE}），无需重新下载。"
                        c_ok "已找回U盘（/dev/${p} → $MNT），继续写入 ..."
                        return 0
                    fi
                    umount "$probe" 2>/dev/null || umount -l "$probe" 2>/dev/null || true
                fi
            done
        done
        c_warn "未找到制作中的那只 U盘（nonce 不匹配）。请确认插回的是刚才那只盘，或换一个 USB 口重插。"
    done
}

# 三振包装器（分类表：①盘不在→恢复+计 1 振；②盘在重试 3 次败→Die；③确定性错误不走本函数，保留降级）
usb_retry() {  # $1=标签 $2...=命令
    local label="$1"; shift
    local fail=0
    while true; do
        if "$@"; then return 0; fi
        fail=$((fail + 1))
        if ! usb_alive; then wait_usb_return; fi
        if [ "$fail" -ge 3 ]; then
            die "${label} 连续失败 ${fail} 次（U盘 可能不稳定）。" "下载缓存已保留在本机（${CACHE}），换一只U盘重新运行制作器即可，无需重新下载。"
        fi
        c_warn "${label} 第 ${fail} 次失败，重试 ..."
    done
}

# 整树拷贝（暂存树 → U盘）：rsync 优先（跳过已拷文件=断点续拷）；openrsync/macOS 不在本支持范围
RSYNC_OPTS=(-rt --partial --inplace --no-perms --no-owner)
tree_copy() {  # $1=src树 $2=dest
    mkdir -p "$2"
    if command -v rsync >/dev/null 2>&1; then
        rsync "${RSYNC_OPTS[@]}" "$1/" "$2/"
    else
        # 降级 cp -R：成败由随后的三对账驱动（对账不过 → usb_retry 重拷）
        cp -R "$1/." "$2/"
    fi
}

# 三对账：文件数 + 总字节 + 入口文件非 0 字节
assert_tree_synced() {  # $1=src $2=dst $3=label $4=入口相对路径(空格分隔)
    local sc dc sb db
    sc="$(find "$1" -type f | wc -l)"; dc="$(find "$2" -type f 2>/dev/null | wc -l)"
    [ "$sc" = "$dc" ] || { c_warn "$3 对账失败：文件数 ${dc}/${sc}"; return 1; }
    sb="$(du -sb "$1" | cut -f1)"; db="$(du -sb "$2" | cut -f1)"
    [ "$sb" = "$db" ] || { c_warn "$3 对账失败：总字节数不匹配（暂存 ${sb} / U盘 ${db}）"; return 1; }
    local e
    for e in $4; do
        [ -s "$2/$e" ] || { c_warn "$3 对账失败：入口缺失/为空 $e"; return 1; }
    done
    return 0
}

# 掉盘恢复 + 整树拷贝 + 对账 + 三振 一步到位
# 注意：拷贝前由调用方 rm -rf 目标（干净起点）；本函数内不清场——掉盘恢复重试时保留半成品，rsync 增量续拷
usb_tree_copy_once() {  # $1=src $2=dst $3=label $4=入口(空格分隔)
    tree_copy "$1" "$2" && assert_tree_synced "$1" "$2" "$3" "$4"
}
usb_tree_copy() {  # $1=src $2=dst $3=label $4=入口相对路径(空格分隔)
    usb_retry "$3" usb_tree_copy_once "$1" "$2" "$3" "$4"
}

# 掉盘标识：Ventoy 已写完、数据分区已挂载 → 写 nonce（全新 -i 会清盘，故必须此刻才写）
# 有界输入在前、head 不再半路退（无限 urandom 喂 head 会让 tr 吃 SIGPIPE→141→pipefail 误杀本行）
SESSION_NONCE="$(head -c 4096 /dev/urandom | tr -dc 'a-f0-9' | cut -c1-32)"
printf '%s' "$SESSION_NONCE" > "$MNT/$NONCE_FILE"
printf '%s' "$SESSION_NONCE" > "${CACHE}/session-nonce"

echo ""
echo "    >>> 接下来开始向 U盘 写入文件，此步最慢（小文件多、U盘 写速有限），请勿拔盘 <<< "
mkdir -p "$MNT/ISO" "$MNT/ventoy" "$MNT/config"
# 仅拷实际下载到的组件（未发布的 winpe/memtest86+ 自动跳过）；带进度（pv 优先，dd 兜底）
copy_progress() {  # $1=src $2=destdir
    local name; name="$(basename "$1")"
    echo "    拷入 $name ..."
    if command -v pv >/dev/null 2>&1; then
        pv "$1" > "$2/$name"
    else
        dd if="$1" of="$2/$name" bs=4M status=progress oflag=direct 2>/dev/null \
            || dd if="$1" of="$2/$name" bs=4M status=progress
    fi
}
# 1.7.0 升级提速②：盘中同名镜像 sha256 = 发布侧钉值 → 跳过整文件重写（1.5GB 级写入是升级耗时大头）
# 读校验 ~10-20 秒 vs 重写 3-13 分钟；对不上（含文件缺失）照常重写，不改变既有正确性
dest_same_as_release() {  # $1=src $2=destdir $3=发布侧sha256；一致返回0
    local d; d="$2/$(basename "$1")"
    { [ -n "$3" ] && [ -s "$d" ]; } || return 1
    echo "    校验盘中已有 $(basename "$1") ..."
    [ "$(sha256sum "$d" 2>/dev/null | awk '{print $1}')" = "$3" ]
}
for name in ai-repair-live winpe 'memtest86+'; do
    [ -n "${LOCAL_FILE[$name]:-}" ] || continue
    if dest_same_as_release "${LOCAL_FILE[$name]}" "$MNT/ISO" "${LOCAL_SHA[$name]:-}"; then
        c_ok "盘中 $(basename "${LOCAL_FILE[$name]}") 已是最新（跳过重写）"
        continue
    fi
    usb_retry "镜像 ${name}" copy_progress "${LOCAL_FILE[$name]}" "$MNT/ISO"
done
# 升级模式：清理旧版维修系统 ISO（新版已拷入；旧版留着白占 ~1.4GB）
if [ "$UPGRADE_MODE" = "1" ]; then
    _LIVE_NOW="$(json_get ai-repair-live filename)"
    for _OLD in "$MNT"/ISO/AI-Repair-Live-v*.iso; do
        [ -e "$_OLD" ] || continue
        [ "$(basename "$_OLD")" = "$_LIVE_NOW" ] && continue
        rm -f "$_OLD" && c_ok "已清理旧版维修系统: $(basename "$_OLD")"
    done
fi

# Debian 12 netinst（P-A A4：勾选且下载成功才拷入）
if [ -n "$DEBIAN_ISO" ]; then
    if dest_same_as_release "$DEBIAN_ISO" "$MNT/ISO" "$DEBIAN_SHA"; then
        c_ok "盘中 Debian 镜像已是最新（跳过重写）: ${DEBIAN_NAME}"
    else
        usb_retry "Debian 镜像" copy_progress "$DEBIAN_ISO" "$MNT/ISO"
    fi
    c_ok "已放入 Linux 安装镜像: ${DEBIAN_NAME}"
fi

# ventoy.json：默认启动 AI-Repair-Live、菜单超时 3 秒、中文菜单别名
LIVE_FNAME="$(json_get ai-repair-live filename)"
# P-A A4：勾选 Debian 时增 "/ISO/<debian>" => "安装 Debian 12" 别名分支（未勾选为空，占位行合法）
DEBIAN_ALIAS_LINE=""
if [ -n "$DEBIAN_ISO" ]; then
    DEBIAN_ALIAS_LINE='    { "image": "/ISO/${DEBIAN_NAME}", "alias": "安装 Debian 12" }'
fi
cat > "$MNT/ventoy/ventoy.json" <<EOF
{
  "control": [
    { "VTOY_DEFAULT_MENU_MODE": "0" },
    { "VTOY_MENU_TIMEOUT": "3" },
    { "VTOY_MENU_LANGUAGE": "zh_CN" },
    { "VTOY_DEFAULT_IMAGE": "/ISO/${LIVE_FNAME}" }
  ],
  "boot_menu_alias": [
    { "image": "/ISO/${LIVE_FNAME}", "alias": "AI 电脑维修助手（推荐）" },
    { "image": "/ISO/WinPE_x64.iso", "alias": "WinPE 装机维护环境" },
    { "image": "/ISO/MemTest86+.iso", "alias": "MemTest86+ 内存检测" }${DEBIAN_ALIAS_LINE:+,
    { "image": "/ISO/${DEBIAN_NAME}", "alias": "安装 Debian 12" }}
  ]
}
EOF

cat > "$MNT/config/README.txt" <<'EOF'
AI 电脑维修 U盘 配置目录
- auth_token: 首次使用时由维修助手引导您创建，存放网关访问凭证
- 请勿手动删除本目录
EOF
if [ -f "$MNT/config/settings.conf" ]; then
    c_ok "保留现有 config/settings.conf（现场配置不覆盖）"
else
    cat > "$MNT/config/settings.conf" <<'EOF'
RECORD_MODE=customer
GATEWAY_BASE_URL=https://tokeneff.com
ACTIVATE_URL=https://tokeneff.com/api/usb/activate
BALANCE_URL=https://tokeneff.com/api/usb/balance
PROMO_CODE=
CONFIG_OVERRIDE=1
EOF
fi
printf '%s\n' "$SCRIPT_VERSION" > "$MNT/maker_version"   # 场景③启动器激活上报用（ps1/repair-on-linux.sh 读取）
printf '%s\n' "$VENTOY_VERSION" > "$MNT/ventoy_version"  # 1.7.0 升级提速①：版本一致时下次升级跳过刷引导

# ---------------- 8.5 制作时签发 USB token（可选，可跳过；幂等） ----------------
# 邮箱验证 → 签发 token → 写 config/auth_token；失败不阻塞制作（开机后 welcome.sh 会再引导配置）
usb_portal_post() {  # $1=接口路径 $2=JSON 请求体；成功输出响应体，失败返回非 0
    curl -fsS --max-time 30 -X POST \
        -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' -d "$2" \
        "${PORTAL_API_BASE}${1}" 2>/dev/null
}

usb_verify_body() {  # $1=email $2=code $3=password → verify 请求体（jq/python3 构造，防引号注入；密码空则省略字段）
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg e "$1" --arg c "$2" --arg p "$3" '{email:$e, code:$c} + (if $p=="" then {} else {password:$p} end)'
    else
        python3 -c 'import json,sys; d={"email":sys.argv[1],"code":sys.argv[2]}; sys.argv[3] and d.update(password=sys.argv[3]); print(json.dumps(d))' "$1" "$2" "$3"
    fi
}

usb_email_body() {  # $1=email → request-code 请求体（与 usb_verify_body 同构造器，防 JSON 引号注入）
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg e "$1" '{email:$e}'
    else
        python3 -c 'import json,sys; print(json.dumps({"email": sys.argv[1]}))' "$1"
    fi
}

usb_token_field() {  # $1=字段名 $2=JSON 文本（与 manifest 解析同思路：优先 jq，缺则 python3）
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg f "$1" '.[$f] // empty' <<<"$2"
    else
        python3 -c "import json,sys;print(json.loads(sys.argv[2]).get(sys.argv[1],''))" "$1" "$2"
    fi
}

AUTH_TOKEN_FILE="$MNT/config/auth_token"
if [ -s "$AUTH_TOKEN_FILE" ]; then
    c_ok "检测到已有 AI 服务凭证（config/auth_token），跳过配置"
else
    ask -rp "是否现在配置 AI 服务（免费，只需邮箱验证）？(y/N): " WANT_TOKEN
    if [ "${WANT_TOKEN,,}" = "y" ]; then
        TOKEN_DONE=0
        for attempt in 1 2 3; do   # 首次 + 最多 2 次重试
            ask -rp "请输入邮箱: " USB_EMAIL
            if [ -z "$USB_EMAIL" ]; then
                c_warn "邮箱不能为空（第 ${attempt} 次尝试）"
            elif ! usb_portal_post '/activate/request-code' "$(usb_email_body "$USB_EMAIL")" >/dev/null; then
                c_warn "验证码发送失败，请检查网络（第 ${attempt} 次尝试）"
            else
                c_ok "验证码已发送到邮箱（10 分钟内有效）"
                ask -rp "请输入邮箱收到的 6 位验证码: " USB_CODE
                # v0.3.1：顺手设置登录密码 → 用户可凭邮箱+密码登录 tokeneff.com 查余额/管理 Key
                USB_PWD=""
                while [[ "$USB_CODE" =~ ^[0-9]{6}$ ]]; do
                    c_warn "提示：若该邮箱已注册过官网账号，此密码将同步修改其登录密码。"
                    ask -rsp "设置登录密码（≥8位，登录官网 tokeneff.com 查余额用，输入不回显，直接回车跳过）: " USB_PWD; echo
                    if [ -z "$USB_PWD" ]; then
                        c_warn "已跳过设置密码（将来无法登录官网查询余额）"
                        break
                    fi
                    ask -rsp "请再次输入密码: " USB_PWD2; echo
                    if [ "${#USB_PWD}" -lt 8 ]; then c_warn "密码至少 8 位"; continue; fi
                    if [ "$USB_PWD" != "$USB_PWD2" ]; then c_warn "两次输入不一致"; continue; fi
                    break
                done
                if [[ "$USB_CODE" =~ ^[0-9]{6}$ ]] \
                    && VERIFY_RESP="$(usb_portal_post '/activate/verify' "$(usb_verify_body "$USB_EMAIL" "$USB_CODE" "$USB_PWD")")" \
                    && USB_TOKEN="$(usb_token_field token "$VERIFY_RESP")" \
                    && { [ -n "$USB_TOKEN" ] || USB_TOKEN="$(usb_token_field usb_token "$VERIFY_RESP")"; } \
                    && [ -n "$USB_TOKEN" ]; then
                    printf '%s' "$USB_TOKEN" > "$AUTH_TOKEN_FILE"
                    c_ok "AI 服务凭证已写入 U盘（config/auth_token），开机后可直接使用"
                    TOKEN_DONE=1
                    break
                fi
                c_warn "验证码校验失败（第 ${attempt} 次尝试）"
            fi
            if [ "$attempt" -lt 3 ]; then
                ask -rp "是否重试？(Y/n): " TOKEN_RETRY
                [ "${TOKEN_RETRY,,}" = "n" ] && break
            fi
        done
        [ "$TOKEN_DONE" = "1" ] || c_warn "未完成 AI 服务配置。不影响 U盘 制作——开机进入维修系统后会再引导您配置。"
    else
        c_warn "已跳过。开机进入维修系统后也会引导您完成配置。"
    fi
fi

# 1.7.3：小文件投放统一先落本机暂存、成功后再拷上U盘——fetch_retry 直写 $MNT 时失败会留半截文件
# 污染U盘根/config（残留入口还会被下轮检测误判为成品盘）；*.ps1 落盘前补 UTF-8 BOM
# （PS5.1 无 BOM 按 GBK 解析，中文注释直接炸——与 ps1 侧 ventoy.json 的 BOM 坑同源反向）
usb_place_file() {  # $1=url $2=目标绝对路径
    local url="$1" dst="$2" tmp
    tmp="${WORKDIR}/place-$$.$(basename "$dst")"
    if ! fetch_retry "$url" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    case "$dst" in
        *.ps1)
            # 缺 BOM（EF BB BF）则前置；head -c 3 有界输入，pipefail 下安全
            if [ "$(head -c 3 "$tmp" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ]; then
                { printf '\xEF\xBB\xBF'; cat "$tmp"; } > "${tmp}.bom" && mv -f "${tmp}.bom" "$tmp" || return 1
            fi
            ;;
    esac
    mkdir -p "$(dirname "$dst")"
    # 1.7.5：同盘暂存+原子改名——WORKDIR(/tmp)→U盘是跨设备，mv 退化 copy+unlink，
    # 中途失败（ENOSPC/掉盘）会在真实文件名上留半截（入口文件还是成品盘识别文件）；
    # 改拷 .ai-part（名字无害）再同盘改名，失败清暂存
    if cp "$tmp" "${dst}.ai-part" && mv -f "${dst}.ai-part" "$dst"; then
        return 0
    fi
    rm -f "${dst}.ai-part"
    return 1
}

# 场景③ 在线维修入口（P-A A4 双入口投放：AI-Workstation.bat 与 bat 同内容，设计 §9-3；1.4.0 加 Linux 入口）
for f in repair-on-windows.bat repair-on-windows.ps1 AI-Workstation.bat repair-on-linux.sh; do
    if usb_place_file "https://usb.tokeneff.com/maker/$f" "$MNT/$f"; then
        c_ok "已放在线维修入口: $f"
    else
        c_warn "$f 获取失败（下载/落盘）——在线维修入口缺失，不影响 U盘 启动维修"
    fi
done

# 办公助手人格（P-A A2/A4）：config/office/CLAUDE.md（勾选了 claude 才投放）
if [ "$WANT_CLAUDE" = "1" ]; then
    mkdir -p "$MNT/config/office"
    if usb_place_file "https://usb.tokeneff.com/maker/office-CLAUDE.md" "$MNT/config/office/CLAUDE.md"; then
        c_ok "已放入: config/office/CLAUDE.md（办公助手人格）"
    else
        c_warn "office-CLAUDE.md 获取失败。不影响制作——办公模式将以通用模式启动。"
    fi
fi

# 维修技能（6 个，与 Live ISO 内置同源）：config/claude-skills/<名>/SKILL.md（勾选了 claude 才投放）
if [ "$WANT_CLAUDE" = "1" ]; then
    got=0
    for n in systematic-debugging verification-before-completion smart-diagnosis data-rescue network-triage reinstall-guardrail; do
        mkdir -p "$MNT/config/claude-skills/$n"
        if usb_place_file "https://usb.tokeneff.com/maker/claude-skills/$n.md" "$MNT/config/claude-skills/$n/SKILL.md"; then
            got=$((got+1))
        fi
    done
    if [ "$got" -gt 0 ]; then
        c_ok "已放入: config/claude-skills/（维修技能 $got/6 个）"
    else
        c_warn "claude-skills 获取失败（0/6）。不影响制作——维修会话将以无技能模式启动。"
    fi
fi

# 1.7.1 升级提速②：便携运行时同版本跳拷（盘上 bin/*.ver 标记 = 当前版本 → 跳过解压+重拷；
# 仅升级模式生效，读不到（旧盘）→ 照常写；标记与 ps1 侧同名互认，规则同 ventoy_version）
ver_skip() {  # $1=标记相对路径 $2=期望版本 $3=抽查文件相对路径
    [ "$UPGRADE_MODE" = "1" ] || return 1
    [ -n "$2" ] || return 1
    [ -e "$MNT/$3" ] || return 1
    [ "$(tr -d '[:space:]' < "$MNT/$1" 2>/dev/null)" = "$(printf '%s' "$2" | tr -d '[:space:]')" ]
}
# 1.7.5：写失败容错——树已拷完仅缺标记时，下次升级重拷一次即可，不该被 set -e 打死整轮
ver_mark() { printf '%s\n' "$2" > "$MNT/$1" || c_warn "版本标记 $1 写入失败（下次升级将重拷一次）"; }

# Codex CLI 落盘（P-A A3/A4：bin/codex.exe + config/codex/config.toml）
CODEX_INSTALLED=0
CODEX_CURRENT=0   # 1.7.5：盘上 codex 为本版 sha 复核通过的（终验门控；fallback 沿用旧版时 0）
if [ -n "$CODEX_EXE" ]; then
    mkdir -p "$MNT/bin" "$MNT/config/codex"
    if ver_skip bin/codex.ver "$CODEX_VER" bin/codex.exe; then
        c_ok "盘上 codex.exe 已是 ${CODEX_VER}（版本一致，跳过重拷）"
        CODEX_CURRENT=1
    else
        usb_retry "Codex CLI" cp "$CODEX_EXE" "$MNT/bin/codex.exe"
        ver_mark bin/codex.ver "$CODEX_VER"
        CODEX_CURRENT=1
    fi
    cat > "$MNT/config/codex/config.toml" <<'TOML'
# Codex CLI 配置（制作器生成；AI 维修U盘 P-A）
model_provider = "tokeneff"
model = "glm-5.2"

[model_providers.tokeneff]
name = "tokeneff gateway"
base_url = "https://tokeneff.com/v1"
env_key = "TOKENEFF_API_KEY"
wire_api = "responses"
TOML
    CODEX_INSTALLED=1
    c_ok "已放入: bin/codex.exe + config/codex/config.toml"
elif [ "$UPGRADE_MODE" = "1" ] && [ "$WANT_CODEX" = "1" ] && [ -e "$MNT/bin/codex.exe" ]; then
    CODEX_INSTALLED=1
    c_warn "codex 新版获取失败——沿用盘上已有版本（不阻断制作）"
fi

# Node / OpenClaw / Pi 落盘（P-B §3.3-3.5：bin/node/ + bin/openclaw/ + bin/pi/）
# 1.3.7 两段式：先解压到本机暂存（快、可重试），再 rsync 整树拷入U盘（断点续拷+对账+掉盘恢复）
NODE_INSTALLED=0; OC_INSTALLED=0; PI_INSTALLED=0
mkdir -p "${WORKDIR}/extract"
if [ -n "$NODE_TAR" ]; then
    NODE_STAGE="${WORKDIR}/extract/node"
    # 1.7.4 同版本跳拷补漏：1.7.1 只做了四件套，Node/OpenClaw/Pi 漏网（每次升级白解压+重拷）
    if ver_skip bin/node.ver "$NODE_VER" bin/node/node.exe; then
        NODE_INSTALLED=1
        c_ok "盘上 bin/node 已是 ${NODE_VER}（版本一致，跳过解压与重拷）"
    else
    echo "    解压便携 Node（本机暂存）..."
    # 注意用 -f 不用 -x：zip 内 node.exe 无执行位（external_attr=0），Linux 解出 0664；
    # 该 exe 是 Windows 载荷，Linux 侧只做存在性判断
    if extract_progress "便携 Node" "$NODE_STAGE" unzip -qo "$NODE_TAR" -d "$NODE_STAGE" \
        && INNER="$(find "$NODE_STAGE" -maxdepth 1 -mindepth 1 -type d | head -n1)" \
        && [ -f "$INNER/node.exe" ] \
        && rm -rf "$MNT/bin/node" \
        && usb_tree_copy "$INNER" "$MNT/bin/node" "便携 Node" "node.exe"; then
        NODE_INSTALLED=1
        ver_mark bin/node.ver "$NODE_VER"
        c_ok "已落盘: bin/node/（便携 Node 运行时）"
    else
        c_warn "便携 Node 落盘失败。OpenClaw/Pi 将无法运行，不阻断制作。"
    fi
    fi
elif [ "$UPGRADE_MODE" = "1" ] && [ "$WANT_NODE" = "1" ] && [ -e "$MNT/bin/node/node.exe" ]; then
    NODE_INSTALLED=1
    c_warn "便携 Node 新版包获取失败——沿用盘上已有版本（不阻断制作）"
fi
if [ -n "$OC_TAR" ]; then
    OC_STAGE="${WORKDIR}/extract/openclaw"
    if ver_skip bin/openclaw.ver "$OC_VER" bin/openclaw/node_modules/openclaw/openclaw.mjs; then
        OC_INSTALLED=1
        c_ok "盘上 bin/openclaw 已是 ${OC_VER}（版本一致，跳过解包与重拷）"
    else
    echo "    解包 OpenClaw 预装包（本机暂存）..."
    # tar 内为 node_modules/ 顶层；预装包已 --dereference 烤平符号链接（exFAT 兼容）
    extract_progress "OpenClaw" "$OC_STAGE" tar -xzf "$OC_TAR" -C "$OC_STAGE" || true
    if [ -f "$OC_STAGE/node_modules/openclaw/openclaw.mjs" ] \
        && rm -rf "$MNT/bin/openclaw" \
        && usb_tree_copy "$OC_STAGE" "$MNT/bin/openclaw" "OpenClaw" "node_modules/openclaw/openclaw.mjs"; then
        OC_INSTALLED=1
        ver_mark bin/openclaw.ver "$OC_VER"
        c_ok "已落盘: bin/openclaw/（入口 node_modules/openclaw/openclaw.mjs）"
    else
        c_warn "OpenClaw 落盘失败。不阻断制作——启动器不显示其入口。"
    fi
    fi
elif [ "$UPGRADE_MODE" = "1" ] && [ "$WANT_OPENCLAW" = "1" ] && [ -e "$MNT/bin/openclaw/node_modules/openclaw/openclaw.mjs" ]; then
    OC_INSTALLED=1
    c_warn "OpenClaw 新版包获取失败——沿用盘上已有版本（不阻断制作）"
fi
if [ -n "$PI_TAR" ]; then
    PI_STAGE="${WORKDIR}/extract/pi"
    if ver_skip bin/pi.ver "$PI_VER" bin/pi/node_modules/@mariozechner/pi-coding-agent/dist/cli.js; then
        PI_INSTALLED=1
        c_ok "盘上 bin/pi 已是 ${PI_VER}（版本一致，跳过解包与重拷）"
    else
    echo "    解包 Pi 预装包（本机暂存）..."
    extract_progress "Pi" "$PI_STAGE" tar -xzf "$PI_TAR" -C "$PI_STAGE" || true
    if [ -f "$PI_STAGE/node_modules/@mariozechner/pi-coding-agent/dist/cli.js" ] \
        && rm -rf "$MNT/bin/pi" \
        && usb_tree_copy "$PI_STAGE" "$MNT/bin/pi" "Pi" "node_modules/@mariozechner/pi-coding-agent/dist/cli.js"; then
        PI_INSTALLED=1
        ver_mark bin/pi.ver "$PI_VER"
        c_ok "已落盘: bin/pi/（入口 node_modules/@mariozechner/pi-coding-agent/dist/cli.js）"
    else
        c_warn "Pi 落盘失败。不阻断制作——启动器不显示其入口。"
    fi
    fi
elif [ "$UPGRADE_MODE" = "1" ] && [ "$WANT_PI" = "1" ] && [ -e "$MNT/bin/pi/node_modules/@mariozechner/pi-coding-agent/dist/cli.js" ]; then
    PI_INSTALLED=1
    c_warn "Pi 新版包获取失败——沿用盘上已有版本（不阻断制作）"
fi

# 场景③便携运行时 → U盘 bin\（claude.exe 直跑 + MinGit 提供 bash）
if [ -n "$CLAUDE_EXE" ]; then
    mkdir -p "$MNT/bin"
    if ver_skip bin/claude-win.ver "$CLAUDE_VER" bin/claude.exe; then
        CLAUDE_OK=1
        c_ok "盘上 claude.exe 已是 ${CLAUDE_VER}（版本一致，跳过重拷）"
    else
        echo "    拷入 claude.exe ..."
        usb_retry "claude.exe" cp "$CLAUDE_EXE" "$MNT/bin/claude.exe"
        actual="$(sha256sum "$MNT/bin/claude.exe" | awk '{print $1}')"
        if [ "${actual,,}" = "${CLAUDE_SHA,,}" ]; then
            c_ok "bin/claude.exe 盘上复核通过"
            ver_mark bin/claude-win.ver "$CLAUDE_VER"
            CLAUDE_OK=1
            # 1.7.3：成功提示移入复核通过分支——否则 sha 失败移除后仍误报「已放入」
            c_ok "便携版 claude.exe 已放入 U盘 bin/"
        else
            rm -f "$MNT/bin/claude.exe"
            c_warn "bin/claude.exe 拷贝后校验失败，已移除（不阻断制作）——场景③将回落为在线安装。"
        fi
    fi
elif [ "$UPGRADE_MODE" = "1" ] && [ "$WANT_CLAUDE" = "1" ] && [ -e "$MNT/bin/claude.exe" ]; then
    # 1.7.5：新版获取失败的升级沿用盘上旧版——不隐藏能用的入口（不写标记，下轮会正常升级）
    CLAUDE_OK=1
    c_warn "claude.exe 新版获取失败——沿用盘上已有版本（不阻断制作）"
fi
# 场景③ Linux 便携引擎 → U盘 bin/（repair-on-linux.sh 读 bin/claude-linux + .sha256 旁车强校验）
if [ -n "$CLAUDE_LINUX" ]; then
    mkdir -p "$MNT/bin"
    if ver_skip bin/claude-linux.ver "$CLAUDE_VER" bin/claude-linux; then
        c_ok "盘上 claude-linux 已是 ${CLAUDE_VER}（版本一致，跳过重拷）"
    else
        echo "    拷入 claude-linux ..."
        usb_retry "claude-linux" cp "$CLAUDE_LINUX" "$MNT/bin/claude-linux"
        actual="$(sha256sum "$MNT/bin/claude-linux" | awk '{print $1}')"
        if [ "${actual,,}" = "${CLAUDE_LINUX_SHA,,}" ]; then
            printf '%s\n' "$CLAUDE_LINUX_SHA" > "$MNT/bin/claude-linux.sha256"
            ver_mark bin/claude-linux.ver "$CLAUDE_VER"
            c_ok "bin/claude-linux 盘上复核通过（.sha256 旁车已写）"
        else
            rm -f "$MNT/bin/claude-linux" "$MNT/bin/claude-linux.sha256"
            c_warn "bin/claude-linux 拷贝后校验失败，已移除（不阻断制作）——Linux 启动器将回落本机/在线。"
        fi
    fi
fi
if [ -n "$MINGIT_ZIP" ]; then
    mkdir -p "$MNT/bin"
    if ver_skip bin/portablegit.ver "$PORTABLE_GIT_VERSION" bin/PortableGit/bin/git.exe; then
        c_ok "盘上便携 Git 已是 v${PORTABLE_GIT_VERSION}（版本一致，跳过解压与重拷）"
    else
        GIT_STAGE="${WORKDIR}/extract/PortableGit"
        echo "    解压便携 Git（本机暂存）..."
        if extract_progress "便携 Git" "$GIT_STAGE" unzip -qo "$MINGIT_ZIP" -d "$GIT_STAGE" \
            && rm -rf "$MNT/bin/PortableGit" \
            && usb_tree_copy "$GIT_STAGE" "$MNT/bin/PortableGit" "便携 Git" "bin/git.exe"; then
            ver_mark bin/portablegit.ver "$PORTABLE_GIT_VERSION"
            c_ok "便携 Git 已落盘到 U盘 bin/PortableGit"
        else
            c_warn "便携 Git 落盘失败，已跳过（不阻断制作）"
        fi
    fi
fi

# agents.json / isos.json（P-A A4：启动器据此显隐入口；语义与设计 §4.0 对齐）
#   installed=true → 列出并启动；userDeclined=true → 灰色行；两者皆无 → 隐藏
CLAUDE_INSTALLED=0; [ "$CLAUDE_OK" = "1" ] && CLAUDE_INSTALLED=1   # 1.7.5：挂盘上复核结果，不再以缓存路径判（sha 失败移除后曾谎报已装）
CLAUDE_DECLINED=0; [ "$WANT_CLAUDE" = "1" ] || CLAUDE_DECLINED=1
CODEX_DECLINED=0; [ "$WANT_CODEX" = "1" ] || CODEX_DECLINED=1
# P-B：OpenClaw/Pi/Node 勾选语义同上（node 非「引擎」，但启动器据此决定是否 PATH 前置 bin/node）
OC_DECLINED=0;   [ "$WANT_OPENCLAW" = "1" ] || OC_DECLINED=1
PI_DECLINED=0;   [ "$WANT_PI" = "1" ] || PI_DECLINED=1
NODE_DECLINED=0; [ "$WANT_NODE" = "1" ] || NODE_DECLINED=1
# 1.3.7：写盘前守卫（组件段间隙掉盘 → 恢复后再写）
usb_alive || wait_usb_return
if command -v jq >/dev/null 2>&1; then
    jq -n \
        --argjson ci "$CLAUDE_INSTALLED" --argjson cd "$CLAUDE_DECLINED" \
        --argjson xi "$CODEX_INSTALLED" --argjson xd "$CODEX_DECLINED" \
        --argjson xavail "$CODEX_AVAILABLE" \
        --argjson oi "$OC_INSTALLED" --argjson od "$OC_DECLINED" --argjson oavail "$OC_AVAILABLE" --arg over "$OC_VER" \
        --argjson pi2 "$PI_INSTALLED" --argjson pd "$PI_DECLINED" --argjson pavail "$PI_AVAILABLE" --arg pver "$PI_VER" \
        --argjson ni "$NODE_INSTALLED" --argjson nd "$NODE_DECLINED" --argjson navail "$NODE_AVAILABLE" --arg nver "$NODE_VER" \
        '{claude:{installed:$ci,userDeclined:$cd}} + (if $xavail==1 then {codex:{installed:$xi,userDeclined:$xd}} else {} end) + (if $oavail==1 then {openclaw:{installed:$oi,userDeclined:$od,version:$over}} else {} end) + (if $pavail==1 then {pi:{installed:$pi2,userDeclined:$pd,version:$pver}} else {} end) + (if $navail==1 then {node:{installed:$ni,userDeclined:$nd,version:$nver}} else {} end)' \
        > "$MNT/config/agents.json.tmp"
    mv -f "$MNT/config/agents.json.tmp" "$MNT/config/agents.json"
else
    python3 - "$CLAUDE_INSTALLED" "$CLAUDE_DECLINED" "$CODEX_INSTALLED" "$CODEX_DECLINED" "$CODEX_AVAILABLE" \
        "$OC_INSTALLED" "$OC_DECLINED" "$OC_AVAILABLE" "$OC_VER" \
        "$PI_INSTALLED" "$PI_DECLINED" "$PI_AVAILABLE" "$PI_VER" \
        "$NODE_INSTALLED" "$NODE_DECLINED" "$NODE_AVAILABLE" "$NODE_VER" \
        > "$MNT/config/agents.json.tmp" <<'PYJS'
import json, sys
ci, cd, xi, xd, xa = map(int, sys.argv[1:6])
oi, od, oa, ov = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8]), sys.argv[9]
pi_i, pd, pa, pv = int(sys.argv[10]), int(sys.argv[11]), int(sys.argv[12]), sys.argv[13]
ni, nd, na, nv = int(sys.argv[14]), int(sys.argv[15]), int(sys.argv[16]), sys.argv[17]
d = {"claude": {"installed": bool(ci), "userDeclined": bool(cd)}}
if xa:
    d["codex"] = {"installed": bool(xi), "userDeclined": bool(xd)}
if oa:
    d["openclaw"] = {"installed": bool(oi), "userDeclined": bool(od), "version": ov}
if pa:
    d["pi"] = {"installed": bool(pi_i), "userDeclined": bool(pd), "version": pv}
if na:
    d["node"] = {"installed": bool(ni), "userDeclined": bool(nd), "version": nv}
print(json.dumps(d, indent=2))
PYJS
    mv -f "$MNT/config/agents.json.tmp" "$MNT/config/agents.json"
fi
if [ -n "$DEBIAN_ISO" ]; then
    printf '{\n  "debian": {\n    "filename": "%s",\n    "sha256": "%s",\n    "source": "%s"\n  }\n}\n' \
        "$DEBIAN_NAME" "$DEBIAN_SHA" "$DEBIAN_URL" > "$MNT/config/isos.json"
else
    printf '{}\n' > "$MNT/config/isos.json"
fi
c_ok "已写入: config/agents.json + config/isos.json（AI 引擎勾选记录）"

sync
c_ok "镜像与配置拷入完成"
echo "    正在等待系统刷盘/杀毒扫描完成，可能需要几分钟，请勿拔盘 ..."

# ---------------- 9. 逐文件 SHA256 复核 ----------------
c_step "正在做最终校验 ..."
for name in ai-repair-live winpe 'memtest86+'; do
    [ -n "${LOCAL_FILE[$name]:-}" ] || continue   # 未发布组件未拷入，跳过复核
    fname="$(json_get "$name" filename)"; sha="$(json_get "$name" sha256)"
    [ -n "$sha" ] || continue                     # 无哈希（动态解析的官方包）跳过
    sha_check "$MNT/ISO/$fname" "$sha" "$fname"
done
# Codex 盘上复核（P-A A4：勾选且已落盘才校验；未勾选不得因缺失报错）
if [ "$CODEX_INSTALLED" = "1" ]; then
    # 1.7.5：仅对本版校验通过的拷贝做终验 sha（fallback 沿用旧版时盘上是旧 sha，验新 sha 必误杀）
    if [ "$CODEX_CURRENT" = "1" ]; then
        sha_check "$MNT/bin/codex.exe" "$CODEX_SHA" "bin/codex.exe"
    fi
    [ -f "$MNT/config/codex/config.toml" ] || die "config/codex/config.toml 缺失。" "请重新运行制作器。"
fi
# Debian 盘上复核（勾选且已拷入才校验）
if [ -n "$DEBIAN_ISO" ]; then
    sha_check "$MNT/ISO/$DEBIAN_NAME" "$DEBIAN_SHA" "$DEBIAN_NAME"
fi
# Node / OpenClaw / Pi 盘上复核（P-B：勾选且已落盘才校验；解压产物整树无 sha，校验关键入口存在性）
if [ "$NODE_INSTALLED" = "1" ]; then
    [ -f "$MNT/bin/node/node.exe" ] || die "bin/node/node.exe 缺失。" "请重新运行制作器。"
fi
if [ "$OC_INSTALLED" = "1" ]; then
    [ -f "$MNT/bin/openclaw/node_modules/openclaw/openclaw.mjs" ] || die "bin/openclaw 入口缺失。" "请重新运行制作器。"
fi
if [ "$PI_INSTALLED" = "1" ]; then
    [ -f "$MNT/bin/pi/node_modules/@mariozechner/pi-coding-agent/dist/cli.js" ] || die "bin/pi 入口缺失。" "请重新运行制作器。"
fi
sync
echo ""
if [ "$UPGRADE_MODE" = "1" ]; then
    printf '\033[32m===============================================\033[0m\n'
    printf '\033[32m  无损升级完成！盘中文件、凭证、配置均已保留。\033[0m\n'
    printf '\033[32m===============================================\033[0m\n'
else
    printf '\033[32m===============================================\033[0m\n'
    printf '\033[32m  制作完成，可以拔下使用了！\033[0m\n'
    printf '\033[32m===============================================\033[0m\n'
fi
echo ""
echo "使用方法: 将 U盘 插入需要维修的电脑 → 开机按启动菜单键(F12/F9/Esc) → 选择 U盘 启动"
if [ -f "$MNT/repair-on-windows.bat" ]; then
    if [ -f "$MNT/bin/claude.exe" ]; then
        echo "电脑还能进 Windows 时: 双击 U盘 根目录 AI-Workstation.bat（或 repair-on-windows.bat），即可在 Windows 内在线维修/办公（免安装直跑，无需重启）"
    else
        echo "电脑还能进 Windows 时: 双击 U盘 根目录 AI-Workstation.bat（或 repair-on-windows.bat），即可在线维修（首次将在线安装 claude）"
    fi
fi
if [ -f "$MNT/repair-on-linux.sh" ]; then
    if [ -f "$MNT/bin/claude-linux" ]; then
        echo "电脑还能进 Linux 时: 打开终端，cd 到U盘目录运行 bash repair-on-linux.sh，即可在 Linux 内在线维修/办公（免安装直跑）"
    else
        echo "电脑还能进 Linux 时: 打开终端，cd 到U盘目录运行 bash repair-on-linux.sh（首次将在线下载 Linux 版 claude）"
    fi
fi
if [ -n "$DEBIAN_ISO" ]; then
    echo "已附带 Debian 12 netinst: 启动菜单选择「安装 Debian 12」即可"
fi
echo "提示: 需要 Windows 安装镜像时，请从微软官网下载 ISO 后拷入 U盘 ISO 目录："
echo "      https://www.microsoft.com/zh-cn/software-download/"
umount "$MNT"
