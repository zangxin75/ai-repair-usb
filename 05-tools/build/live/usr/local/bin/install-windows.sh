#!/usr/bin/env bash
# install-windows.sh —— Windows 无人值守装机编排（设计 §2.3 路径二，Linux 侧阶段）
#
# 用途：
#   1. 列出 /mnt/ventoy/ISO/Win*.iso 供 whiptail 选择（自动推荐：
#      TPM2.0 + 内存≥8GB → Win11，否则 Win10，标注推荐）
#   2. 选目标盘（by-id 排除 U盘 自身 + 二次确认显示盘型号容量）
#   3. parted GPT 分区：ESP(100M,FAT32) + MSR(16M) + 主分区(NTFS)
#   4. 从 ISO 提取 install.wim（优先挂载 loop，7z 兜底）
#   5. wimlib-imagex apply 灌装主分区
#   6. 写入 unattend.xml 到 \Windows\Panther\unattend.xml（跳过 OOBE/隐藏联网账户页）
#   7. 提示重启 → Ventoy 菜单选 WinPE_x64.iso 完成 bcdboot 引导修复（本脚本只打印指引）
#
# 调用方：main-menu.sh 重装系统流程（由 Claude 调用）、装机员手动
# 依赖命令：lsblk parted mkfs.vfat mkfs.ntfs wimlib-imagex 7z mount whiptail tpm2 工具(可选)
# 警告：本脚本会完全清空目标盘全部数据，内置二次确认 + by-id 排除 U盘 自身。
set -euo pipefail

VENTOY_MNT="/mnt/ventoy"
ISO_DIR="$VENTOY_MNT/ISO"

show_help() {
    cat <<'EOF'
用法: sudo install-windows.sh
Windows 无人值守装机（Linux 侧灌装阶段）。
步骤：选镜像 → 选目标盘（二次确认）→ GPT 分区 → 灌装 → 写应答文件 → 重启指引。
完成后需重启并在启动菜单选 WinPE_x64.iso 做引导修复。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

# ---------- 前置：挂载数据分区 ----------
mountpoint -q "$VENTOY_MNT" 2>/dev/null || mount-ventoy-data.sh || {
    echo "无法挂载数据分区，找不到 Windows 镜像。" >&2; exit 1; }

# ---------- 步骤1：选镜像 ----------
mapfile -t ISOS < <(find "$ISO_DIR" -maxdepth 1 -iname 'Win*.iso' 2>/dev/null | sort || true)
[[ ${#ISOS[@]} -gt 0 ]] || {
    echo "在 $ISO_DIR 下没有找到 Windows 镜像（Win*.iso）。" >&2
    echo "请把微软官方下载的 Win10/Win11 ISO 拷贝到 U盘 的 ISO 目录后重试。" >&2
    exit 1
}

# 自动推荐：TPM2.0 + 内存≥8GB → Win11，否则 Win10
REC_KEYWORD="Win10"
MEM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
HAS_TPM=0
[[ -c /dev/tpm0 ]] && HAS_TPM=1
if (( HAS_TPM == 1 && MEM_GB >= 8 )); then REC_KEYWORD="Win11"; fi
echo "    检测结果：内存 ${MEM_GB}GB，TPM2.0 $([ $HAS_TPM -eq 1 ] && echo 有 || echo 无) → 推荐 $REC_KEYWORD"

ITEMS=(); i=1
for iso in "${ISOS[@]}"; do
    base=$(basename "$iso")
    tag=""
    [[ "$base" == *"$REC_KEYWORD"* ]] && tag="（推荐：适合本机配置）"
    ITEMS+=("$i" "$base $tag")
    i=$((i+1))
done
CH=$(whiptail --title "选择 Windows 版本" --menu \
    "选择要安装的镜像：\n（本机内存 ${MEM_GB}GB / TPM2.0 $([ $HAS_TPM -eq 1 ] && echo 有 || echo 无)，已标注推荐）" \
    16 70 6 "${ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1
ISO="${ISOS[$((CH-1))]}"
echo "已选镜像：$(basename "$ISO")"

# ---------- 步骤2：选目标盘（排除 U盘 自身） ----------
is_usb_disk() {
    local dev="$1" link
    for link in /dev/disk/by-id/usb-*; do
        [[ -e "$link" ]] || continue
        [[ "$(readlink -f "$link")" == "$dev" ]] && return 0
    done
    # udev 属性兜底：USB 总线设备
    [[ "$(udevadm info -q property -n "$dev" 2>/dev/null | grep '^ID_BUS=' | cut -d= -f2)" == "usb" ]] && return 0
    return 1
}

mapfile -t ALL_DISKS < <(lsblk -d -n -o NAME,TYPE 2>/dev/null \
    | awk '$2=="disk" {print "/dev/"$1}' | grep -v -E '^/dev/(loop|ram|sr)' || true)
DISKS=()
for d in ${ALL_DISKS[@]+"${ALL_DISKS[@]}"}; do
    is_usb_disk "$d" && { echo "    已排除 U盘/安装介质：$d"; continue; }
    DISKS+=("$d")
done
[[ ${#DISKS[@]} -gt 0 ]] || { echo "未检测到可安装系统的内置硬盘。" >&2; exit 1; }

ITEMS=(); i=1
declare -A DISK_INFO=()
for d in "${DISKS[@]}"; do
    MODEL=$(lsblk -d -n -o MODEL "$d" 2>/dev/null | head -1 | xargs || echo 未知)
    SZB=$(lsblk -d -n -b -o SIZE "$d" 2>/dev/null | head -1)
    SZG=$((SZB/1024/1024/1024))
    BYID=$(ls -l /dev/disk/by-id/ 2>/dev/null | awk -v t="$(basename "$d")" '$NF==t {print $9; exit}' || true)
    ITEMS+=("$i" "$d ${MODEL:-未知} ${SZG}GB [${BYID:-无by-id}]")
    DISK_INFO[$i]="$d|$MODEL|$SZG|${BYID:-无}"
    i=$((i+1))
done
CH=$(whiptail --title "选择目标盘" --menu \
    "Windows 装到哪块硬盘？\n（U盘 自身已被自动排除，不会出现在列表里）" \
    18 76 8 "${ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1
IFS='|' read -r TARGET MODEL SZG BYID <<< "${DISK_INFO[$CH]}"

# ---------- 二次确认（破坏性操作） ----------
# --defaultno 放在位置参数之前（标准用法，避免 newt 解析差异 —— verifier B8）
whiptail --defaultno --title "最后确认（将清空整块硬盘）" --yesno \
"即将执行的操作：
把 $(basename "$ISO") 安装到硬盘 $TARGET

目标盘信息：$MODEL，约 ${SZG}GB（$BYID）

影响：该硬盘上的全部分区和全部文件将被彻底清空，无法恢复。

确认无误？（默认 No）" 16 66 || { echo "用户已取消。"; exit 0; }

echo "正在对 $TARGET 分区（GPT：ESP 100M + MSR 16M + 主分区）…"

# ---------- 步骤3：parted GPT 分区 ----------
umount "${TARGET}"* 2>/dev/null || true
parted -s "$TARGET" mklabel gpt
parted -s "$TARGET" mkpart ESP fat32 1MiB 101MiB
parted -s "$TARGET" set 1 esp on
parted -s "$TARGET" mkpart MSR 101MiB 117MiB
parted -s "$TARGET" set 2 msftres on
parted -s "$TARGET" mkpart Primary ntfs 117MiB 100%
sleep 2
partprobe "$TARGET" 2>/dev/null || true
sleep 2

# 分区节点命名（nvme: p1 / sata: 1）
if [[ "$TARGET" == *nvme* || "$TARGET" == *mmcblk* ]]; then
    ESP="${TARGET}p1"; MAIN="${TARGET}p3"
else
    ESP="${TARGET}1"; MAIN="${TARGET}3"
fi
[[ -b "$ESP" && -b "$MAIN" ]] || { echo "分区节点未出现：$ESP / $MAIN" >&2; exit 1; }

mkfs.vfat -F32 "$ESP" >/dev/null
mkfs.ntfs -f -L Windows "$MAIN" >/dev/null
echo "分区完成：ESP=$ESP  主分区=$MAIN"

# ---------- 步骤4：提取 install.wim ----------
ISO_MNT="/mnt/iso_$$"
WIN_MNT="/mnt/win_target_$$"
mkdir -p "$ISO_MNT" "$WIN_MNT"
cleanup() {
    umount "$WIN_MNT" 2>/dev/null || true
    umount "$ISO_MNT" 2>/dev/null || true
    rmdir "$ISO_MNT" "$WIN_MNT" 2>/dev/null || true
}
trap cleanup EXIT

WIM_PATH=""
if mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null; then
    for cand in "$ISO_MNT/sources/install.wim" "$ISO_MNT/sources/install.esd"; do
        [[ -f "$cand" ]] && WIM_PATH="$cand" && break
    done
fi
if [[ -z "$WIM_PATH" ]]; then
    echo "直接挂载失败，改用 7z 提取 install.wim…"
    umount "$ISO_MNT" 2>/dev/null || true
    EXTRACT_DIR="/tmp/wim_extract_$$"
    mkdir -p "$EXTRACT_DIR"
    7z e "$ISO" sources/install.wim -o"$EXTRACT_DIR" >/dev/null
    WIM_PATH="$EXTRACT_DIR/install.wim"
fi
[[ -f "$WIM_PATH" ]] || { echo "镜像内找不到 install.wim/install.esd。" >&2; exit 1; }

# 列镜像索引让用户选版本
echo "镜像内的版本列表："
wimlib-imagex info "$WIM_PATH" | awk '/^Index:|^Display Name:/'
INDEX=$(whiptail --title "选择系统版本" --inputbox \
    "上面是镜像内包含的版本列表。\n请输入要安装的版本序号（Index 号，一般选专业版对应的数字）：" \
    12 60 "2" 3>&1 1>&2 2>&3) || exit 1

# ---------- 步骤5：灌装 ----------
ntfs-3g "$MAIN" "$WIN_MNT"
echo "正在灌装系统到 $MAIN（约 5-8 分钟，请勿断电）…"
wimlib-imagex apply "$WIM_PATH" "$INDEX" "$WIN_MNT"

# ---------- 步骤6：unattend.xml ----------
mkdir -p "$WIN_MNT/Windows/Panther"
cat > "$WIN_MNT/Windows/Panther/unattend.xml" <<'UNATTEND'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>zh-CN</InputLocale>
      <SystemLocale>zh-CN</SystemLocale>
      <UILanguage>zh-CN</UILanguage>
      <UserLocale>zh-CN</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>user</Name>
            <Group>Administrators</Group>
            <Password><Value></Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>user</Username>
        <LogonCount>1</LogonCount>
      </AutoLogon>
    </component>
  </settings>
</unattend>
UNATTEND
echo "应答文件已写入 \\Windows\\Panther\\unattend.xml（跳过联网账户页，自动创建本机账户 user）"

sync
umount "$WIN_MNT"

# ---------- 步骤7：重启指引 ----------
whiptail --title "灌装完成 · 下一步" --msgbox \
"系统文件已写入硬盘。还需一步「引导修复」才能开机：

1. 重启电脑（拔掉网线不用管，选确认后会重启）
2. 在启动菜单（Ventoy）选择 WinPE_x64.iso
3. 进入 WinPE 后按屏幕提示执行引导修复（bcdboot）
   —— WinPE 里有中文操作菜单，跟着选即可
4. 完成后重启，从硬盘启动，系统会自动完成初始化

现在重启？" 18 62 && reboot || echo "请稍后手动重启并选择 WinPE_x64.iso。"
