# build-mac-dualboot.ps1 版本: 0.1-experiment  (AI 电脑维修 U盘 · Mac 双引导实验脚本)
# 创建日期: 2026-10-17 / 版本 0.1 / 状态: 实验脚本（未并入正式制作器）/ 作者: Claude Code + kt
#
# 目的：给现有 Ventoy U盘 增加「Mac 直启分区」，解决 Intel Mac 上 Ventoy 黑屏问题。
#   原理：不碰 Ventoy（part1 数据 + part2 VTOYEFI），只把 part1 缩小 128MB，
#         在腾出的空间建 part3（FAT32），放独立 grub 引导器 loopback 直启 ISO。
#   PC 照常走 Ventoy；Intel Mac 开机 Option 出现两个「EFI Boot」，选 grub 那个。
#   Apple Silicon（M 系列）固件不支持第三方 USB 引导，本方案对其无效。
#
# 风险与回滚：
#   - 缩容/建分区不动 part1 数据，但任何磁盘操作前请自行备份 config\ 下凭证等重要文件
#   - 回滚 = 删掉 part3 即可（Get-Partition 删除 MACGRUB 分区），Ventoy 完全不受影响
#   - grub 菜单为纯 ASCII（standalone 二进制未带 unicode 字体，中文会乱码）
#
# 真机验证状态（2026-10-17）：grub 载荷经 OVMF/qemu 两轮引导链测试通过；
#   Apple 启动选择器是否列出第二个 EFI Boot 图标 —— 待 MacBook Air 2011 实测。

$ErrorActionPreference = 'Stop'
$PayloadUrl  = 'https://usb.tokeneff.com/downloads/mac-grub-efi-0.1.zip'
$PayloadSha  = '5ba9db217f8b46641471e1fb793bc13cebc4a2876c1c3e144da4049e92254f95'
$GrubSizeMB  = 128

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[警告] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[失败] $m" -ForegroundColor Red; Read-Host '按回车键退出'; exit 1 }

# 需要管理员（磁盘操作）
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die '请以管理员身份运行 PowerShell 后再执行本脚本。' }

# ---------------- 1. 定位 Ventoy U盘（安全选择：USB 总线 + exFAT 卷上有 Live ISO） ----------------
Write-Step '正在定位 Ventoy U盘 ...'
$usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })
if ($usbDisks.Count -eq 0) { Die '未检测到任何 USB 磁盘。' }

$target = $null; $dataVol = $null
foreach ($d in $usbDisks) {
    $vols = @(Get-Partition -DiskNumber $d.DiskNumber -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue |
              Where-Object { $_.DriveLetter })
    $hit = $vols | Where-Object { (Get-ChildItem -LiteralPath "$($_.DriveLetter):\" -Filter 'AI-Repair-Live-*.iso' -ErrorAction SilentlyContinue) }
    if ($hit) { $target = $d; $dataVol = @($hit)[0]; break }
}
if (-not $target) { Die 'USB 盘上没找到 AI-Repair-Live-*.iso——不是本项目的 Ventoy 盘？' }

Write-Host ("  目标: 磁盘 {0}  {1}  {2:N1}GB  数据分区 {3}: ({4})" -f `
    $target.DiskNumber, $target.FriendlyName, ($target.Size/1GB), $dataVol.DriveLetter, $dataVol.FileSystemLabel)

if ($target.PartitionStyle -eq 'MBR' -and @($target | Get-Partition).Count -ge 4) {
    Die 'MBR 布局 4 个主分区已满，无法再加分区。'
}

$ans = Read-Host "确认对这只 U盘执行【缩容 128MB + 新建 grub 分区】？盘上数据不动 (y/N)"
if ($ans -notin @('y','Y')) { Die '用户取消。' }

# ---------------- 2. 下载 grub 载荷（带 sha 校验） ----------------
Write-Step '正在下载 grub 引导载荷 ...'
$tmpZip = Join-Path $env:TEMP 'mac-grub-efi-0.1.zip'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $PayloadUrl -OutFile $tmpZip -UseBasicParsing
$actual = (Get-FileHash $tmpZip -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $PayloadSha) { Remove-Item $tmpZip -Force; Die "载荷 sha256 校验失败（$actual）。" }
Expand-Archive -Path $tmpZip -DestinationPath "$env:TEMP\mac-grub-payload" -Force
$grubEfi = "$env:TEMP\mac-grub-payload\grubx64-0.1.efi"
if (-not (Test-Path $grubEfi)) { Die '载荷包内容异常（缺 grubx64-0.1.efi）。' }
Write-Ok '载荷下载并校验通过'

# ---------------- 3. 缩容数据分区 + 新建 FAT32 分区 ----------------
Write-Step "正在缩容数据分区（腾 ${GrubSizeMB}MB）..."
$dataPart = Get-Partition -DiskNumber $target.DiskNumber -DriveLetter $dataVol.DriveLetter
$newSize = $dataPart.Size - $GrubSizeMB * 1MB
try {
    Resize-Partition -DiskNumber $target.DiskNumber -DriveLetter $dataVol.DriveLetter -Size $newSize | Out-Null
} catch {
    Die "缩容失败（$($_.Exception.Message)）。盘未做任何改动。可试 diskpart: shrink desired=$GrubSizeMB 后重跑本脚本（已建分区会被识别跳过）。"
}
Write-Ok '缩容完成'

Write-Step '正在新建 FAT32 grub 分区 ...'
$newPart = New-Partition -DiskNumber $target.DiskNumber -UseMaximumSize -AssignDriveLetter
$gVol = $newPart | Get-Volume
if (-not $gVol.DriveLetter) {          # -AssignDriveLetter 已知不总生效，手动补
    $used = @(Get-Volume | ForEach-Object { $_.DriveLetter }) | Where-Object { $_ }
    $free = 68..90 | ForEach-Object { [char]$_ } | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    Set-Partition -DiskNumber $target.DiskNumber -PartitionNumber $newPart.PartitionNumber -NewDriveLetter $free
    $gVol = $newPart | Get-Volume
}
Format-Volume -DriveLetter $gVol.DriveLetter -FileSystem FAT32 -NewFileSystemLabel 'MACGRUB' -Force | Out-Null
$gRoot = "$($gVol.DriveLetter):"
Write-Ok "grub 分区: $gRoot (MACGRUB)"

# ---------------- 4. 写入引导文件 + 按盘上实际 ISO 生成菜单 ----------------
Write-Step '正在写入引导文件 ...'
New-Item -ItemType Directory -Path "$gRoot\EFI\BOOT", "$gRoot\EFI\mac" -Force | Out-Null
Copy-Item $grubEfi "$gRoot\EFI\BOOT\BOOTX64.EFI" -Force
Set-Content -Path "$gRoot\EFI\mac\boot.marker" -Value 'ai-repair-mac-dualboot' -NoNewline -Encoding ascii

$liveIso = Get-ChildItem -LiteralPath "$($dataVol.DriveLetter):\" -Filter 'AI-Repair-Live-*.iso' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$netinst = Get-ChildItem -LiteralPath "$($dataVol.DriveLetter):\" -Filter 'debian-*-netinst*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1

$cfg = New-Object System.Text.StringBuilder
[void]$cfg.AppendLine('set timeout=10')
[void]$cfg.AppendLine('set default=0')
[void]$cfg.AppendLine("menuentry 'AI-Repair Live (Mac direct boot)' --id=live {")
[void]$cfg.AppendLine("  search --no-floppy --set=vd --file /$($liveIso.Name)")
[void]$cfg.AppendLine("  loopback loop (`${vd})/$($liveIso.Name)")
[void]$cfg.AppendLine('  linux (loop)/live/vmlinuz boot=live components username=live hostname=ai-repair locales=zh_CN.UTF-8 keyboard-layouts=cn')
[void]$cfg.AppendLine('  initrd (loop)/live/initrd.img')
[void]$cfg.AppendLine('}')
if ($netinst) {
    [void]$cfg.AppendLine("menuentry 'Debian netinst installer' --id=netinst {")
    [void]$cfg.AppendLine("  search --no-floppy --set=vd --file /$($netinst.Name)")
    [void]$cfg.AppendLine("  loopback loop (`${vd})/$($netinst.Name)")
    [void]$cfg.AppendLine('  linux (loop)/install.amd/vmlinuz vga=788 --- quiet')
    [void]$cfg.AppendLine('  initrd (loop)/install.amd/initrd.gz')
    [void]$cfg.AppendLine('}')
}
[void]$cfg.AppendLine("menuentry 'Reboot' { reboot }")
[IO.File]::WriteAllText("$gRoot\EFI\mac\grub-real.cfg", $cfg.ToString())
Write-Ok "菜单已生成（Live: $($liveIso.Name)$(if ($netinst) { " + netinst: $($netinst.Name)" })）"

Remove-Item $tmpZip, "$env:TEMP\mac-grub-payload" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '================ 完成 ================' -ForegroundColor Green
Write-Host "Mac 上使用：插入 U盘 → 开机长按 Option(Option/alt) → 启动选择器里可能出现【两个 EFI Boot】"
Write-Host '  - 选 Ventoy 黑屏的那个是 Ventoy（Mac 上不可用）'
Write-Host '  - 选能进【grub 菜单】的那个 → AI-Repair Live 直启'
Write-Host '  - 只出现一个 EFI Boot 且仍是黑屏：把现象拍照/描述反馈，本方案对此机型不生效'
Write-Host 'PC 上使用：完全不变，照常 Ventoy。'
Write-Host '回滚：管理员 PowerShell 执行  Get-Partition | Where-Object FileSystemLabel -eq MACGRUB | Remove-Partition -Confirm:$false'
Read-Host '按回车键退出'
