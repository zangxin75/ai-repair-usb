#!/usr/bin/env bash
# usb-v1.0.sh 版本: 1.0.0  (AI 电脑维修 U盘 一键制作器 · Linux 端)
# =====================================================================
# 创建日期: 2026-09-12
# 版本: 1.0.0
# 状态: 草稿（Ventoy CLI 参数待 K0 实测后定稿，见 TODO(K0)）
# 设计依据: 技术方案_AI电脑维修U盘_总体设计_20260912.md §2.5.2 / §2.5.3
#
# 重要说明（§2.5.2 定稿决策）：Linux 端【不下载 Win10/Win11 ISO】。
# 原因：Fido 式微软官方直链解析为 PowerShell 实现，无 bash 等价物；
# Linux 用户制作完成后请手动从微软官网下载 ISO 拷入 U盘 ISO 目录：
#   https://www.microsoft.com/zh-cn/software-download/
#
# 用法（官网一键命令）:
#   curl -sL https://tokeneff.com/usb-v1.0.sh | sudo bash
# 审阅后再执行（推荐）:
#   curl -sLO https://tokeneff.com/usb-v1.0.sh && less usb-v1.0.sh && sudo bash usb-v1.0.sh
# =====================================================================
set -euo pipefail

# ---------------- 全局常量（集中定义） ----------------
SCRIPT_VERSION="1.0.0"
MANIFEST_URL="https://tokeneff.com/manifest.json"   # TODO(发布): 迁移到独立 CDN 域名（§2.5.4 故障隔离）
MIN_DISK_GB=64
HTTP_TIMEOUT=30
MAX_RETRY=3
WORKDIR="$(mktemp -d /tmp/ai-repair-usb-maker.XXXXXX)"

# ---- TODO(K0): Ventoy CLI 实测参数对照表（K0 验证后替换为实测值）----
# K0 验证要点：Ventoy2Disk.sh -i 非交互行为、-g(GPT)/-r(保留空间MB) 参数名与取值、退出码
VENTOY_RESERVE_MB=2048                                          # TODO(K0): 保留空间实测确认
VENTOY_SH_ARGS_TEMPLATE="-i -g -r ${VENTOY_RESERVE_MB}"         # TODO(K0): 以实测参数对照表为准

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
[ "$(id -u)" -eq 0 ] || die "需要 root 权限。" "请使用: curl -sL https://tokeneff.com/usb-v1.0.sh | sudo bash"
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
[ "${#USB_DISKS[@]}" -gt 0 ] || die "未检测到 U盘。" "请插入容量 ≥64GB 的 U盘 后重新运行。"

echo ""
echo "检测到以下 USB 磁盘："
i=1
for d in "${USB_DISKS[@]}"; do
    read -r size model < <(lsblk -d -n -o SIZE,MODEL "/dev/$d" | head -n1)
    printf '  [%d] /dev/%s  |  %s  |  %s\n' "$i" "$d" "${model:-未知型号}" "${size:-未知容量}"
    i=$((i+1))
done
echo ""
# 单候选也需用户确认一次
read -rp "请输入要制作的 U盘 编号（1-${#USB_DISKS[@]}）: " SEL
[[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#USB_DISKS[@]}" ] \
    || die "输入的编号无效。" "请重新运行并输入列表中的编号。"
TARGET_NAME="${USB_DISKS[$((SEL-1))]}"
TARGET_DEV="/dev/${TARGET_NAME}"
SIZE_BYTES="$(lsblk -d -n -b -o SIZE "$TARGET_DEV" | head -n1 | tr -d ' ')"
SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
[ "$SIZE_GB" -ge "$MIN_DISK_GB" ] \
    || die "所选 U盘 容量约 ${SIZE_GB}GB，小于最低要求 ${MIN_DISK_GB}GB。" "请更换容量 ≥64GB（推荐 128GB）的 U盘。"

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
declare -A LOCAL_FILE=()
for name in ventoy ai-repair-live winpe 'memtest86+'; do
    url="$(json_get "$name" url)";       [ -n "$url" ] || die "manifest 中组件 $name 缺少 url。" ""
    fname="$(json_get "$name" filename)"; [ -n "$fname" ] || die "manifest 中组件 $name 缺少 filename。" ""
    sha="$(json_get "$name" sha256)"
    dest="${WORKDIR}/${fname}"
    echo "    下载 ${name} (${fname}) ..."
    fetch_retry "$url" "$dest" || die "组件 $name 下载失败。" "请检查网络后重新运行。"
    sha_check "$dest" "$sha" "$fname"
    LOCAL_FILE[$name]="$dest"
done

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
# shellcheck disable=SC2086
bash "$VENTOY_SH" $VENTOY_SH_ARGS_TEMPLATE "$TARGET_DEV" \
    || die "Ventoy 写入失败。" "请重新插拔 U盘后重试；若反复失败请换一只 U盘。"
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
cp "${LOCAL_FILE[ai-repair-live]}" "$MNT/ISO/"
cp "${LOCAL_FILE[winpe]}" "$MNT/ISO/"
cp "${LOCAL_FILE['memtest86+']}" "$MNT/ISO/"

# ventoy.json：默认启动 AI-Repair-Live、菜单超时 3 秒、中文菜单别名
LIVE_FNAME="$(json_get ai-repair-live filename)"
cat > "$MNT/ventoy/ventoy.json" <<EOF
{
  "control": [
    { "VTOY_DEFAULT_MENU_MODE": "0" },
    { "VTOY_MENU_TIMEOUT": "3" },
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
sync
c_ok "镜像与配置拷入完成"

# ---------------- 9. 逐文件 SHA256 复核 ----------------
c_step "正在做最终校验 ..."
for name in ai-repair-live winpe 'memtest86+'; do
    fname="$(json_get "$name" filename)"; sha="$(json_get "$name" sha256)"
    sha_check "$MNT/ISO/$fname" "$sha" "$fname"
done
umount "$MNT"

echo ""
printf '\033[32m===============================================\033[0m\n'
printf '\033[32m  制作完成，可以拔下使用了！\033[0m\n'
printf '\033[32m===============================================\033[0m\n'
echo ""
echo "使用方法: 将 U盘 插入需要维修的电脑 → 开机按启动菜单键(F12/F9/Esc) → 选择 U盘 启动"
echo "提示: 需要 Windows 安装镜像时，请从微软官网下载 ISO 后拷入 U盘 ISO 目录："
echo "      https://www.microsoft.com/zh-cn/software-download/"
