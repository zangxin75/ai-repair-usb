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
# Live ISO（盘上没有时自动下载到数据分区根目录；URL/sha 与 manifest.json 组件表一致）
$LiveIsoName = 'AI-Repair-Live-v0.3-20261014.iso'
$LiveIsoUrl  = 'https://usb.tokeneff.com/downloads/' + $LiveIsoName
$LiveIsoSha  = 'e1d22e55160e40f49acf2874995b5e985e4322b3ace997563b1c86413a7480fc'
$LiveIsoSize = 1587609600

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[警告] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[失败] $m" -ForegroundColor Red; Read-Host '按回车键退出'; exit 1 }

# 需要管理员（磁盘操作）
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die '请以管理员身份运行 PowerShell 后再执行本脚本。' }

# ---------------- 1. 定位 Ventoy U盘（优先：USB 总线 + 盘上有 Live ISO；回落：VTOYEFI/Ventoy 卷标） ----------------
Write-Step '正在定位 Ventoy U盘 ...'
$usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })
if ($usbDisks.Count -eq 0) { Die '未检测到任何 USB 磁盘。' }

$target = $null; $dataVol = $null; $needIso = $false
foreach ($d in $usbDisks) {
    $vols = @(Get-Partition -DiskNumber $d.DiskNumber -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue |
              Where-Object { $_.DriveLetter })
    $hit = $vols | Where-Object {
        Get-ChildItem -LiteralPath "$($_.DriveLetter):\" -Filter 'AI-Repair-Live-*.iso' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    }
    if ($hit) { $target = $d; $dataVol = $hit; break }
}
if (-not $target) {
    # 回落：按 Ventoy 卷标认盘（part1 数据卷 label=Ventoy 或 part2 VTOYEFI），Live ISO 事后再下
    foreach ($d in $usbDisks) {
        $vols = @(Get-Partition -DiskNumber $d.DiskNumber -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveLetter })
        $data = $vols | Where-Object { $_.FileSystemLabel -eq 'Ventoy' } | Select-Object -First 1
        $efi  = $vols | Where-Object { $_.FileSystemLabel -eq 'VTOYEFI' }
        if ($data -and $efi) { $target = $d; $dataVol = $data; $needIso = $true; break }
    }
}
if (-not $target) { Die '未找到 Ventoy U盘（既无 AI-Repair-Live-*.iso，也无 Ventoy/VTOYEFI 卷标）。' }
if ($needIso) { Write-Warn "盘上没有 Live ISO，稍后将下载 $LiveIsoName（约 1.5GB）到 $($dataVol.DriveLetter):\" }

Write-Host ("  目标: 磁盘 {0}  {1}  {2:N1}GB  数据分区 {3}: ({4})" -f `
    $target.DiskNumber, $target.FriendlyName, ($target.Size/1GB), $dataVol.DriveLetter, $dataVol.FileSystemLabel)

if ($target.PartitionStyle -eq 'MBR' -and @($target | Get-Partition).Count -ge 4) {
    Die 'MBR 布局 4 个主分区已满，无法再加分区。'
}

$ans = Read-Host "确认对这只 U盘执行【缩容 128MB + 新建 grub 分区】？盘上数据不动 (y/N)"
if ($ans -notin @('y','Y')) { Die '用户取消。' }

# ---------------- 1b. 盘上缺 Live ISO 时自动下载（钉 sha256） ----------------
if ($needIso) {
    Write-Step "正在下载 $LiveIsoName（约 1.5GB，视网速可能 10 分钟以上）..."
    $isoPath = "$($dataVol.DriveLetter):\$LiveIsoName"
    $ProgressPreference = 'SilentlyContinue'   # PS5.1 下 IWR 进度条会把大文件下载拖慢一个数量级
    $dlOk = $false
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L --fail --retry 3 -o $isoPath $LiveIsoUrl
        if ($LASTEXITCODE -eq 0 -and (Test-Path $isoPath)) { $dlOk = $true }
    }
    if (-not $dlOk) {
        Invoke-WebRequest -Uri $LiveIsoUrl -OutFile $isoPath -UseBasicParsing
        $dlOk = $true
    }
    $isoItem = Get-Item -LiteralPath $isoPath -ErrorAction SilentlyContinue
    if (-not $isoItem -or $isoItem.Length -ne $LiveIsoSize) {
        if ($isoItem) { Remove-Item $isoItem -Force }
        Die 'ISO 下载后尺寸不符，已删除残留文件。请检查网络后重试。'
    }
    $actual = (Get-FileHash $isoPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $LiveIsoSha) { Remove-Item $isoPath -Force; Die "ISO sha256 校验失败（$actual）。" }
    Write-Ok 'Live ISO 下载并校验通过'
}

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
$dataPart = Get-Partition -DriveLetter $dataVol.DriveLetter
$newSize = $dataPart.Size - $GrubSizeMB * 1MB
try {
    Resize-Partition -DriveLetter $dataVol.DriveLetter -Size $newSize -ErrorAction Stop | Out-Null
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

# 递归搜盘（ISO 可能在子目录，如 \ISO\），并换算成 grub 相对路径（/ISO/xxx.iso）
# 盘上可能同时有新旧版本（如 v0.1 与 v0.3 并存）：优先精确钉版文件名，其次取最新
$allLive = @(Get-ChildItem -LiteralPath "$($dataVol.DriveLetter):\" -Filter 'AI-Repair-Live-*.iso' -Recurse -ErrorAction SilentlyContinue)
$liveIso = $allLive | Where-Object Name -eq $LiveIsoName | Select-Object -First 1
if (-not $liveIso) { $liveIso = $allLive | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
$netinst = Get-ChildItem -LiteralPath "$($dataVol.DriveLetter):\" -Filter 'debian-*-netinst*.iso' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
if (-not $liveIso) { Die '内部错误：ISO 定位与下载均未完成。' }
function Get-GrubRel([IO.FileSystemInfo]$f) { '/' + ($f.FullName.Substring(3) -replace '\\','/') }   # F:\ISO\a.iso -> /ISO/a.iso
$liveRel  = Get-GrubRel $liveIso
$netRel   = if ($netinst) { Get-GrubRel $netinst }

# 注意：内嵌配置把 prefix 指到了 (root)/EFI/mac，那只是菜单文件目录；模块（linux/linuxefi 等）
# 全在内嵌 memdisk 里，必须在执行菜单项前把 prefix 改回去，否则 linux 命令 autoload 报
# "linuxefi.mod not found" → initrd 报 "you need to load the kernel first"（2011 Air 实测）。
$cfg = New-Object System.Text.StringBuilder
[void]$cfg.AppendLine('set prefix=(memdisk)/boot/grub')
[void]$cfg.AppendLine('set timeout=10')
[void]$cfg.AppendLine('set default=0')
[void]$cfg.AppendLine("menuentry 'AI-Repair Live (Mac direct boot)' --id=live {")
[void]$cfg.AppendLine("  search --no-floppy --set=vd --file $liveRel")
[void]$cfg.AppendLine("  loopback loop (`${vd})$liveRel")
[void]$cfg.AppendLine("  linux (loop)/live/vmlinuz boot=live components username=live hostname=ai-repair locales=zh_CN.UTF-8 keyboard-layouts=cn findiso=$liveRel")
[void]$cfg.AppendLine('  initrd (loop)/live/initrd.img')
[void]$cfg.AppendLine('}')
if ($netinst) {
    [void]$cfg.AppendLine("menuentry 'Debian netinst installer' --id=netinst {")
    [void]$cfg.AppendLine("  search --no-floppy --set=vd --file $netRel")
    [void]$cfg.AppendLine("  loopback loop (`${vd})$netRel")
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
