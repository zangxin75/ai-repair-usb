#!/usr/bin/env bash
# usb-v1.0.sh 版本: 1.1.0  (AI 电脑维修 U盘 一键制作器 · Linux 端)
# =====================================================================
# 创建日期: 2026-09-12
# 版本: 1.1.0
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
# =====================================================================
set -euo pipefail

# ---------------- 全局常量（集中定义） ----------------
SCRIPT_VERSION="1.0.0"
MANIFEST_URL="https://usb.tokeneff.com/maker/manifest.json"   # TODO(发布): 迁移到独立 CDN 域名（§2.5.4 故障隔离）
MIN_DISK_GB=8
HTTP_TIMEOUT=30
MAX_RETRY=3
PORTAL_API_BASE="https://tokeneff.com/api/usb"   # 制作时签发 USB token 的 portal 接口前缀（换域名改这里）
WORKDIR="$(mktemp -d /tmp/ai-repair-usb-maker.XXXXXX)"

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
trap 'rm -rf "$WORKDIR"' EXIT

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

# ---------------- 4. 枚举 USB 磁盘（硬过滤） ----------------
c_step "正在检测已插入的 U盘 ..."
# 只列 TRAN=usb 的整块磁盘 —— 硬过滤系统盘/内置盘（§2.5.3-2）
mapfile -t USB_DISKS < <(lsblk -d -n -o NAME,TRAN | awk '$2=="usb"{print $1}')
[ "${#USB_DISKS[@]}" -gt 0 ] || die "未检测到 U盘。" "请插入容量 ≥8GB 的 U盘 后重新运行。"

# 候选 = 容量 ≥8GB 的 USB 磁盘；小存储（读卡器/加密狗）提示后忽略
MIN_BYTES=$((64 * 1024 * 1024 * 1024))
CANDIDATES=()
for d in "${USB_DISKS[@]}"; do
    sz=$(lsblk -d -n -o SIZE -b "/dev/$d" 2>/dev/null || lsblk -d -n -o SIZE "/dev/$d" | head -n1)
    bytes=$(numfmt --from=auto "$sz" 2>/dev/null || echo 0)
    if [ "$bytes" -ge "$MIN_BYTES" ]; then
        CANDIDATES+=("$d")
    else
        model=$(lsblk -d -n -o MODEL "/dev/$d" | head -n1)
        echo "  已忽略 /dev/$d（${model:-未知型号}，容量不足 8 GB，非制作目标）"
    fi
done
[ "${#CANDIDATES[@]}" -gt 0 ] || die "所有 USB 磁盘容量均不足 8 GB。" "请更换容量 ≥8GB（推荐 128GB）的 U盘 后重新运行。"

echo ""
usb_size() { lsblk -d -n -o SIZE,MODEL "/dev/$1" | head -n1; }
if [ "${#CANDIDATES[@]}" -eq 1 ]; then
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
    read -rp "请输入要制作的 U盘 编号（1-${#CANDIDATES[@]}）: " SEL
    [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#CANDIDATES[@]}" ] \
        || die "输入的编号无效。" "请重新运行并输入列表中的编号。"
    TARGET_NAME="${CANDIDATES[$((SEL-1))]}"
fi
TARGET_DEV="/dev/${TARGET_NAME}"
SIZE_BYTES="$(lsblk -d -n -b -o SIZE "$TARGET_DEV" | head -n1 | tr -d ' ')"
SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
[ "$SIZE_GB" -ge "$MIN_DISK_GB" ] \
    || die "所选 U盘 容量约 ${SIZE_GB}GB，小于最低要求 ${MIN_DISK_GB}GB。" "请更换容量 ≥8GB（推荐 128GB）的 U盘。"

# ---------------- 5. 毁盘警告 + YES 确认 ----------------
echo ""
printf '\033[31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
printf '\033[31m  严重警告：制作过程将清空该 U盘 上的全部数据！\033[0m\n'
printf '\033[31m  目标: %s （约 %dGB）\033[0m\n' "$TARGET_DEV" "$SIZE_GB"
printf '\033[31m  该操作不可恢复，请先备份 U盘 中的重要文件。\033[0m\n'
printf '\033[31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
read -rp "确认继续请输入大写 YES: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "已取消，未对 U盘 做任何修改。"; exit 0; }

# ---------------- 6. 下载自产组件 + SHA256 校验 ----------------
c_step "开始下载组件（curl 断点续传）..."
sha_check() {  # $1=file $2=expected $3=display
    [ -n "$2" ] || { c_warn "$3 未提供 SHA256，跳过校验（manifest 占位阶段）"; return 0; }
    local actual
    actual="$(sha256sum "$1" | awk '{print $1}')"
    [ "${actual,,}" = "${2,,}" ] \
        || die "$3 SHA256 校验失败！期望 $2，实际 $actual。文件可能被篡改或下载损坏。" "请重新运行；若反复失败请联系客服。"
    c_ok "$3 校验通过"
}
# Ventoy 官方直链（manifest url 为空时的兜底；Linux 端用 tar.gz 包）
VENTOY_VERSION="1.1.18"
VENTOY_ASSET="ventoy-${VENTOY_VERSION}-linux.tar.gz"
VENTOY_URL_BASE="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/${VENTOY_ASSET}"

# 场景③便携运行时（v0.2 决策）：Claude Code 官方 GCS 分发桶 + 自托管便携 Git（Bash 工具依赖）
CLAUDE_GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
PORTABLE_GIT_URL="https://usb.tokeneff.com/downloads/PortableGit-2.56.0.2-64-bit.zip"
PORTABLE_GIT_SHA="8e4cb757edb480c6e94ff3858352c2ea1e431cf5bc15d5df3fd56e2904c18dab"

declare -A LOCAL_FILE=()
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
    dest="${WORKDIR}/${fname}"
    echo "    下载 ${name} (${fname}) ..."
    fetch_retry "$url" "$dest" || die "组件 $name 下载失败。" "请检查网络后重新运行。"
    sha_check "$dest" "$sha" "$fname"
    LOCAL_FILE[$dl_key]="$dest"
done

# ---------------- 6.5 场景③便携运行时：claude.exe + MinGit（可选，失败不阻断） ----------------
# U盘 bin\ 内置后，任意 Windows 双击 repair-on-windows.bat 免安装直跑；
# 失败只警告：双击入口自动回落在线安装（方案 5.3 降级链不变）
CLAUDE_EXE=""; CLAUDE_SHA=""
MINGIT_ZIP=""
mkdir -p "${WORKDIR}/portable-bin"
if CLAUDE_VER="$(fetch_retry "${CLAUDE_GCS_BASE}/stable" - | tr -d '[:space:]')" && [ -n "$CLAUDE_VER" ]; then
    CLAUDE_MANIFEST="${CLAUDE_GCS_BASE}/${CLAUDE_VER}/manifest.json"
    CLAUDE_SHA="$(fetch_retry "$CLAUDE_MANIFEST" - | sed -n 's/.*"win32-x64"[^C]*"checksum": "\([0-9a-f]*\)".*/\1/p' | head -n1)"
    if [ -z "$CLAUDE_SHA" ]; then
        c_warn "无法从官方 manifest 取得 win32-x64 checksum，跳过便携版 claude.exe（不阻断制作）。"
    elif fetch_retry "${CLAUDE_GCS_BASE}/${CLAUDE_VER}/win32-x64/claude.exe" "${WORKDIR}/portable-bin/TempClaude.exe"; then
        actual="$(sha256sum "${WORKDIR}/portable-bin/TempClaude.exe" | awk '{print $1}')"
        if [ "${actual,,}" = "${CLAUDE_SHA,,}" ]; then
            mv "${WORKDIR}/portable-bin/TempClaude.exe" "${WORKDIR}/portable-bin/claude.exe"
            CLAUDE_EXE="${WORKDIR}/portable-bin/claude.exe"
            c_ok "便携版 claude.exe 就绪（${CLAUDE_VER}，官方 sha256 校验通过）"
        else
            rm -f "${WORKDIR}/portable-bin/TempClaude.exe"
            c_warn "便携版 claude.exe sha256 校验失败，已跳过（不阻断制作）——场景③将回落为在线安装。"
        fi
    else
        c_warn "便携版 claude.exe 下载失败。不阻断制作——场景③双击入口将回落为在线安装。"
    fi
else
    c_warn "Claude Code 官方分发桶不可达，跳过便携版 claude.exe（不阻断制作）。"
fi
echo "    便携 Git（Bash 工具依赖，约 154MB）..."
if fetch_retry "$PORTABLE_GIT_URL" "${WORKDIR}/portable-bin/TempPortableGit.zip"; then
    actual="$(sha256sum "${WORKDIR}/portable-bin/TempPortableGit.zip" | awk '{print $1}')"
    if [ "${actual,,}" = "${PORTABLE_GIT_SHA,,}" ]; then
        mv "${WORKDIR}/portable-bin/TempPortableGit.zip" "${WORKDIR}/portable-bin/PortableGit.zip"
        MINGIT_ZIP="${WORKDIR}/portable-bin/PortableGit.zip"
        c_ok "便携 Git 就绪（2.56.0.2，自托管 sha256 校验通过）"
    else
        rm -f "${WORKDIR}/portable-bin/TempPortableGit.zip"
        c_warn "便携 Git sha256 校验失败，已跳过（不阻断制作）——目标电脑已装 Git 时不受影响，未装则 Bash 工具受限。"
    fi
else
    c_warn "便携 Git 下载失败。不阻断制作——目标电脑已装 Git 时不受影响，未装则 Bash 工具受限。"
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
# 卸载目标盘上所有已挂载分区，避免写入冲突
lsblk -n -o MOUNTPOINT "$TARGET_DEV" | grep -v '^$' | while read -r mp; do umount "$mp" || true; done
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
    PCT=$(grep -o '[0-9]\{1,3\}%' "${WORKDIR}/ventoy-cli.log" 2>/dev/null | tail -n1 | tr -d '%')
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
for name in ai-repair-live winpe 'memtest86+'; do
    [ -n "${LOCAL_FILE[$name]:-}" ] && copy_progress "${LOCAL_FILE[$name]}" "$MNT/ISO"
done

# ventoy.json：默认启动 AI-Repair-Live、菜单超时 3 秒、中文菜单别名
LIVE_FNAME="$(json_get ai-repair-live filename)"
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
    { "image": "/ISO/MemTest86+.iso", "alias": "MemTest86+ 内存检测" }
  ]
}
EOF

cat > "$MNT/config/README.txt" <<'EOF'
AI 电脑维修 U盘 配置目录
- auth_token: 首次使用时由维修助手引导您创建，存放网关访问凭证
- 请勿手动删除本目录
EOF

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
    read -rp "是否现在配置 AI 服务（免费，只需邮箱验证）？(y/N): " WANT_TOKEN
    if [ "${WANT_TOKEN,,}" = "y" ]; then
        TOKEN_DONE=0
        for attempt in 1 2 3; do   # 首次 + 最多 2 次重试
            read -rp "请输入邮箱: " USB_EMAIL
            if [ -z "$USB_EMAIL" ]; then
                c_warn "邮箱不能为空（第 ${attempt} 次尝试）"
            elif ! usb_portal_post '/activate/request-code' "{\"email\": \"$USB_EMAIL\"}" >/dev/null; then
                c_warn "验证码发送失败，请检查网络（第 ${attempt} 次尝试）"
            else
                c_ok "验证码已发送到邮箱（10 分钟内有效）"
                read -rp "请输入邮箱收到的 6 位验证码: " USB_CODE
                # v0.3.1：顺手设置登录密码 → 用户可凭邮箱+密码登录 tokeneff.com 查余额/管理 Key
                USB_PWD=""
                while [[ "$USB_CODE" =~ ^[0-9]{6}$ ]]; do
                    c_warn "提示：若该邮箱已注册过官网账号，此密码将同步修改其登录密码。"
                    read -rsp "设置登录密码（≥8位，登录官网 tokeneff.com 查余额用，输入不回显，直接回车跳过）: " USB_PWD; echo
                    if [ -z "$USB_PWD" ]; then
                        c_warn "已跳过设置密码（将来无法登录官网查询余额）"
                        break
                    fi
                    read -rsp "请再次输入密码: " USB_PWD2; echo
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
                read -rp "是否重试？(Y/n): " TOKEN_RETRY
                [ "${TOKEN_RETRY,,}" = "n" ] && break
            fi
        done
        [ "$TOKEN_DONE" = "1" ] || c_warn "未完成 AI 服务配置。不影响 U盘 制作——开机进入维修系统后会再引导您配置。"
    else
        c_warn "已跳过。开机进入维修系统后也会引导您完成配置。"
    fi
fi

# 场景③ Windows 在线维修双击入口（repair-on-windows.bat/.ps1，与制作脚本同源同目录）
for f in repair-on-windows.bat repair-on-windows.ps1; do
    if fetch_retry "https://usb.tokeneff.com/maker/$f" "$MNT/$f"; then
        c_ok "已放入 Windows 在线维修入口: $f"
    else
        c_warn "$f 下载失败（Windows 在线维修入口缺失，不影响 U盘 启动维修）"
    fi
done

# 场景③便携运行时 → U盘 bin\（claude.exe 直跑 + MinGit 提供 bash）
if [ -n "$CLAUDE_EXE" ]; then
    mkdir -p "$MNT/bin"
    echo "    拷入 claude.exe ..."
    cp "$CLAUDE_EXE" "$MNT/bin/claude.exe"
    actual="$(sha256sum "$MNT/bin/claude.exe" | awk '{print $1}')"
    if [ "${actual,,}" = "${CLAUDE_SHA,,}" ]; then
        c_ok "bin/claude.exe 盘上复核通过"
    else
        rm -f "$MNT/bin/claude.exe"
        c_warn "bin/claude.exe 拷贝后校验失败，已移除（不阻断制作）——场景③将回落为在线安装。"
    fi
    c_ok "便携版 claude.exe 已放入 U盘 bin/"
fi
if [ -n "$MINGIT_ZIP" ]; then
    mkdir -p "$MNT/bin"
    echo "    解压便携 Git 到 U盘 bin/PortableGit ..."
    if unzip -qo "$MINGIT_ZIP" -d "$MNT/bin/PortableGit"; then
        c_ok "便携 Git 已解压到 U盘 bin/PortableGit"
    else
        rm -rf "$MNT/bin/PortableGit"
        c_warn "便携 Git 解压失败，已跳过（不阻断制作）"
    fi
fi

sync
c_ok "镜像与配置拷入完成"

# ---------------- 9. 逐文件 SHA256 复核 ----------------
c_step "正在做最终校验 ..."
for name in ai-repair-live winpe 'memtest86+'; do
    [ -n "${LOCAL_FILE[$name]:-}" ] || continue   # 未发布组件未拷入，跳过复核
    fname="$(json_get "$name" filename)"; sha="$(json_get "$name" sha256)"
    [ -n "$sha" ] || continue                     # 无哈希（动态解析的官方包）跳过
    sha_check "$MNT/ISO/$fname" "$sha" "$fname"
done
umount "$MNT"

echo ""
printf '\033[32m===============================================\033[0m\n'
printf '\033[32m  制作完成，可以拔下使用了！\033[0m\n'
printf '\033[32m===============================================\033[0m\n'
echo ""
echo "使用方法: 将 U盘 插入需要维修的电脑 → 开机按启动菜单键(F12/F9/Esc) → 选择 U盘 启动"
if [ -f "$MNT/repair-on-windows.bat" ]; then
    if [ -f "$MNT/bin/claude.exe" ]; then
        echo "电脑还能进 Windows 时: 双击 U盘 根目录 repair-on-windows.bat，即可在 Windows 内在线维修（免安装直跑，无需重启）"
    else
        echo "电脑还能进 Windows 时: 双击 U盘 根目录 repair-on-windows.bat，即可在线维修（首次将在线安装 claude）"
    fi
fi
echo "提示: 需要 Windows 安装镜像时，请从微软官网下载 ISO 后拷入 U盘 ISO 目录："
echo "      https://www.microsoft.com/zh-cn/software-download/"
