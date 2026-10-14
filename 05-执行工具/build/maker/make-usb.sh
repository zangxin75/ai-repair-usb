#!/usr/bin/env bash
# make-usb.sh — AI 电脑维修 U盘 开发者量产脚本
# =====================================================================
# 创建日期: 2026-09-12
# 版本: 1.0.0
# 状态: 草稿（Ventoy 参数待 K0 实测定稿）
# 用途: 开发/量产环境（Linux 构建机）在已知组件本地路径的情况下制作成品 U盘。
#       与 usb-v1.0.sh（终端用户一键脚本）区别：本脚本面向开发者，不拉 manifest、
#       不弹交互确认以外的流程，支持双版本回滚与产物命名规范。
#
# 用法:
#   sudo ./make-usb.sh /dev/sdX \
#       --live-new ./AI-Repair-Live-v1.1-20260920.iso \
#       [--live-prev ./AI-Repair-Live-v1.0-20260912.iso] \
#       [--winpe ./WinPE_x64.iso] [--memtest ./MemTest86+.iso] \
#       [--win10 ./Win10_22H2_Chinese_x64.iso] [--win11 ./Win11_24H2_Chinese_x64.iso]
# =====================================================================
set -euo pipefail

# ---------------- 常量（集中定义） ----------------
SCRIPT_VERSION="1.0.0"
RESERVE_MB=2048                          # Ventoy 保留空间（供 Live 持久化/日志扩展）
DATA_LABEL="Ventoy"                      # exFAT 数据分区卷标（定稿 §2.1：卷标 Ventoy）
MENU_TIMEOUT=3                           # ventoy.json 菜单超时秒数（定稿 3 秒）
LIVE_KEEP_VERSIONS=2                     # 双版本回滚：数据分区保留最近两版 Live ISO

# TODO(K0): Ventoy2Disk.sh 实测参数对照表（-g GPT、-r 保留空间、-i 非交互），K0 后替换
VENTOY_SH_ARGS="-i -g -r ${RESERVE_MB}"

die() { printf '\033[31m[失败] %s\033[0m\n' "$1" >&2; exit 1; }
ok()  { printf '\033[32m[OK] %s\033[0m\n' "$1"; }
step(){ printf '\n\033[36m==> %s\033[0m\n' "$1"; }

printf 'AI 电脑维修 U盘 量产脚本 v%s（供应链自检：首行注释亦含版本号）\n' "$SCRIPT_VERSION"

# ---------------- 参数解析 ----------------
[ "$(id -u)" -eq 0 ] || die "需要 root 权限（sudo）。"
[ $# -ge 3 ] || { sed -n '2,20p' "$0"; exit 1; }
DEV="$1"; shift
LIVE_NEW=""; LIVE_PREV=""; WINPE=""; MEMTEST=""; WIN10=""; WIN11=""
while [ $# -gt 0 ]; do
    case "$1" in
        --live-new)  LIVE_NEW="$2"; shift 2;;
        --live-prev) LIVE_PREV="$2"; shift 2;;
        --winpe)     WINPE="$2"; shift 2;;
        --memtest)   MEMTEST="$2"; shift 2;;
        --win10)     WIN10="$2"; shift 2;;
        --win11)     WIN11="$2"; shift 2;;
        *) die "未知参数: $1";;
    esac
done
[ -b "$DEV" ] || die "目标设备不存在: $DEV"
[ -f "$LIVE_NEW" ] || die "--live-new 必须指向新版 AI-Repair-Live ISO 文件"

# 产物命名规范校验：AI-Repair-Live-vX.Y-YYYYMMDD.iso（§2.5 任务约定）
check_live_name() {  # $1=path
    local base; base="$(basename "$1")"
    [[ "$base" =~ ^AI-Repair-Live-v[0-9]+\.[0-9]+-[0-9]{8}\.iso$ ]] \
        || die "Live ISO 文件名不符合命名规范 AI-Repair-Live-vX.Y-YYYYMMDD.iso: $base"
}
check_live_name "$LIVE_NEW"
[ -z "$LIVE_PREV" ] || check_live_name "$LIVE_PREV"

# 防误写：只允许 USB 可移动设备
TRAN="$(lsblk -d -n -o TRAN "$DEV" | head -n1 | tr -d ' ')"
[ "$TRAN" = "usb" ] || die "目标设备不是 USB 可移动盘（TRAN=$TRAN）。为防误写，仅允许 USB 盘。"

step "目标确认"
lsblk -d -o NAME,SIZE,MODEL "$DEV"
read -rp "制作将清空 ${DEV} 全部数据，输入大写 YES 确认: " C
[ "$C" = "YES" ] || { echo "已取消。"; exit 0; }

# ---------------- 1. Ventoy 安装（GPT + 保留空间） ----------------
step "安装 Ventoy 引导层（GPT + 保留 ${RESERVE_MB}MB）"
command -v Ventoy2Disk.sh >/dev/null 2>&1 || die "PATH 中未找到 Ventoy2Disk.sh，请先解压 Ventoy linux 包或设置 PATH。"
lsblk -n -o MOUNTPOINT "$DEV" | grep -v '^$' | while read -r mp; do umount "$mp" || true; done
# shellcheck disable=SC2086
Ventoy2Disk.sh $VENTOY_SH_ARGS "$DEV" || die "Ventoy 写入失败。"
ok "Ventoy 写入完成"

# ---------------- 2. 数据分区格 exFAT + 卷标 Ventoy ----------------
step "格式化数据分区为 exFAT（卷标 ${DATA_LABEL}）"
sleep 3; partprobe "$DEV" 2>/dev/null || true; sleep 2
DATA_PART="$(lsblk -n -b -o NAME,SIZE "$DEV" | tail -n +2 | sort -k2 -n | tail -n1 | awk '{print $1}')"
[ -n "$DATA_PART" ] || die "未找到数据分区"
# Ventoy 默认把数据分区格成 exFAT；此处强制重格确保卷标与文件系统一致（TODO(K0): 若 Ventoy 已格好可跳过本步）
command -v mkfs.exfat >/dev/null 2>&1 || die "缺少 mkfs.exfat（sudo apt install exfatprogs）"
mkfs.exfat -n "$DATA_LABEL" "/dev/${DATA_PART}" || die "exFAT 格式化失败"
MNT="$(mktemp -d)"; trap 'umount "$MNT" 2>/dev/null; rm -rf "$MNT"' EXIT
mount "/dev/${DATA_PART}" "$MNT" || die "挂载数据分区失败"
ok "数据分区就绪: /dev/${DATA_PART}"

# ---------------- 3. 拷入组件（含双版本回滚） ----------------
step "拷入组件"
mkdir -p "$MNT/ISO" "$MNT/ventoy" "$MNT/config"

# 双版本回滚：清理旧版 Live，仅保留最近两版，默认指向新版
rm -f "$MNT"/ISO/AI-Repair-Live-v*.iso 2>/dev/null || true
cp "$LIVE_NEW" "$MNT/ISO/"
[ -z "$LIVE_PREV" ] || cp "$LIVE_PREV" "$MNT/ISO/"
ok "Live ISO 已拷入（保留最近 ${LIVE_KEEP_VERSIONS} 版：新版 + 回滚版）"
[ -z "$WINPE" ]   || cp "$WINPE"   "$MNT/ISO/WinPE_x64.iso"
[ -z "$MEMTEST" ] || cp "$MEMTEST" "$MNT/ISO/MemTest86+.iso"
[ -z "$WIN10" ]   || cp "$WIN10"   "$MNT/ISO/Win10_22H2_Chinese_x64.iso"
[ -z "$WIN11" ]   || cp "$WIN11"   "$MNT/ISO/Win11_24H2_Chinese_x64.iso"

# 逐文件生成 .sha256 校验文件（产物规范：xxx.iso + xxx.iso.sha256）
( cd "$MNT/ISO" && for f in *.iso; do sha256sum "$f" > "$f.sha256"; done )
ok "SHA256 校验文件已生成"

# ---------------- 4. 生成 ventoy.json（默认启动新版 Live / 超时 3 秒 / 中文别名） ----------------
step "生成 ventoy/ventoy.json"
LIVE_NEW_BASE="$(basename "$LIVE_NEW")"
LIVE_PREV_BASE=""; [ -z "$LIVE_PREV" ] || LIVE_PREV_BASE="$(basename "$LIVE_PREV")"
ALIAS_PREV=""
[ -z "$LIVE_PREV_BASE" ] || ALIAS_PREV=$(cat <<EOF
,
    { "image": "/ISO/${LIVE_PREV_BASE}", "alias": "AI 电脑维修助手（上一版，回滚用）" }
EOF
)
cat > "$MNT/ventoy/ventoy.json" <<EOF
{
  "control": [
    { "VTOY_DEFAULT_MENU_MODE": "0" },
    { "VTOY_MENU_TIMEOUT": "${MENU_TIMEOUT}" },
    { "VTOY_MENU_LANGUAGE": "zh_CN" },
    { "VTOY_DEFAULT_IMAGE": "/ISO/${LIVE_NEW_BASE}" }
  ],
  "boot_menu_alias": [
    { "image": "/ISO/${LIVE_NEW_BASE}", "alias": "AI 电脑维修助手（推荐）" }${ALIAS_PREV},
    { "image": "/ISO/WinPE_x64.iso", "alias": "WinPE 装机维护环境" },
    { "image": "/ISO/MemTest86+.iso", "alias": "MemTest86+ 内存检测" },
    { "image": "/ISO/Win10_22H2_Chinese_x64.iso", "alias": "安装 Windows 10" },
    { "image": "/ISO/Win11_24H2_Chinese_x64.iso", "alias": "安装 Windows 11" }
  ]
}
EOF
ok "ventoy.json 已生成（默认启动: ${LIVE_NEW_BASE}，超时 ${MENU_TIMEOUT}s）"

# config 骨架
cat > "$MNT/config/README.txt" <<'EOF'
AI 电脑维修 U盘 配置目录
- auth_token: 首次使用时由维修助手引导您创建，存放网关访问凭证
- 请勿手动删除本目录
EOF

# ---------------- 5. 复核 ----------------
step "逐文件 SHA256 复核"
( cd "$MNT/ISO" && for f in *.iso; do sha256sum -c "$f.sha256" >/dev/null && echo "    [OK] $f"; done )
sync
umount "$MNT"; rm -rf "$MNT"; trap - EXIT

echo ""
ok "量产制作完成：$DEV"
echo "默认启动: AI 电脑维修助手（${LIVE_NEW_BASE}），回滚版: ${LIVE_PREV_BASE:-无}"
echo "产物清单（应归档到发布目录）: ISO 文件 + 对应 .sha256"
