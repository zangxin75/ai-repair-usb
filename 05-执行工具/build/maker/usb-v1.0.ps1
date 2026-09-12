# usb-v1.0.ps1 版本: 1.0.0  (AI 电脑维修 U盘 一键制作器 · Windows 端)
# =====================================================================
# 创建日期: 2026-09-12
# 版本: 1.0.0
# 状态: 草稿（Ventoy CLI 参数待 K0 实测后定稿，见下方 TODO(K0)）
# 兼容: PowerShell 5.1+（Win10/Win11 自带，不依赖第三方工具）
# 设计依据: 技术方案_AI电脑维修U盘_总体设计_20260912.md §2.5
# 用法（官网一键命令）:
#   irm https://tokeneff.com/usb-v1.0.ps1 | iex
# 审阅后再执行（推荐给维修人员）:
#   irm https://tokeneff.com/usb-v1.0.ps1 -OutFile usb.ps1
#   notepad usb.ps1            # 审阅
#   powershell -ExecutionPolicy Bypass -File .\usb.ps1
# =====================================================================

#requires -Version 5.1

# ---------------- 全局常量（集中定义，改这里即可） ----------------
$Script:ScriptVersion   = '1.0.0'
$Script:ScriptUrl       = 'https://tokeneff.com/usb-v1.0.ps1'      # 自提权时按版本化 URL 重新下载自身（见下）
$Script:ManifestUrl     = 'https://tokeneff.com/manifest.json'   # TODO(发布): 迁移到独立 CDN 域名（§2.5.4 故障隔离）
$Script:MinDiskGB       = 64
$Script:HttpTimeoutSec  = 30        # manifest / 小请求超时
$Script:BitsMaxRetry    = 3         # 所有网络操作统一重试次数
$Script:WorkDir         = Join-Path $env:TEMP 'ai-repair-usb-maker'

# ---- TODO(K0): Ventoy CLI 实测参数对照表（K0 验证后替换为实测值）----
# K0 验证要点：Ventoy2Disk.exe -CMD 模式下 ① 非交互安装参数组合 ② 返回码
# ③ 是否需 -Drive 传 "N" 还是 "\\.\PhysicalDriveN" ④ GPT/保留空间开关名
$Script:VentoyExeArgsTemplate = 'VTOY_CLI_INSTALL -Drive:{DRIVE} -Style:GPT -Reserve:{RESERVE_MB} -NUSB'  # TODO(K0): 以实测参数对照表为准
$Script:VentoyReserveMB       = 2048   # TODO(K0): 保留空间实测确认（供 Live 持久化/日志扩展）

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # BITS 不需要 PS 进度条，避免 5.1 下明显卡顿

# ---------------- 工具函数 ----------------

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Write-Ok([string]$msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "    [警告] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "" ; Write-Host "[失败] $msg" -ForegroundColor Red }

function Die([string]$msg, [string]$advice) {
    Write-Fail $msg
    if ($advice) { Write-Host "建议: $advice" -ForegroundColor Yellow }
    Write-Host ""
    Read-Host '按回车键退出'
    exit 1
}

# 带重试的 HTTPS 文本下载（用于 manifest 与小接口请求）
function Get-WebTextWithRetry([string]$Url, [int]$TimeoutSec = 30) {
    $lastErr = $null
    for ($i = 1; $i -le $Script:BitsMaxRetry; $i++) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Timeout = $TimeoutSec * 1000
            $req.UserAgent = "ai-repair-usb-maker/$Script:ScriptVersion"
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
            return $text
        } catch {
            $lastErr = $_
            Write-Warn "请求失败（第 $i/$Script:BitsMaxRetry 次）: $Url"
            if ($i -lt $Script:BitsMaxRetry) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    throw "网络请求多次重试仍失败: $Url （$($lastErr.Exception.Message)）"
}

# BITS 下载大文件 + 重试（§2.5.3 指定 BITS，不自研分块并行）
function Get-FileViaBits([string]$Url, [string]$Dest, [string]$DisplayName) {
    $lastErr = $null
    for ($i = 1; $i -le $Script:BitsMaxRetry; $i++) {
        try {
            if (Test-Path $Dest) { Remove-Item $Dest -Force }
            Write-Host "    下载 $DisplayName（第 $i/$Script:BitsMaxRetry 次尝试）..."
            $job = Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName "AI-Repair-USB: $DisplayName" -ErrorAction Stop
            if (-not (Test-Path $Dest)) { throw "BITS 任务结束但目标文件不存在" }
            return
        } catch {
            $lastErr = $_
            Write-Warn "$DisplayName 下载失败: $($_.Exception.Message)"
            if ($i -lt $Script:BitsMaxRetry) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    throw "下载多次失败: $DisplayName （$($lastErr.Exception.Message)）"
}

function Test-FileSha256([string]$Path, [string]$Expected, [string]$DisplayName) {
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        Write-Warn "$DisplayName 未提供 SHA256，跳过校验（manifest 占位阶段）"
        return
    }
    Write-Host "    校验 $DisplayName SHA256 ..."
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$DisplayName SHA256 校验失败！期望 $Expected，实际 $actual。文件可能被篡改或下载损坏。"
    }
    Write-Ok "$DisplayName 校验通过"
}

# ---------------- 0. 版本输出（供应链自检，§2.5.5-③） ----------------
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  AI 电脑维修 U盘 一键制作器" -ForegroundColor Cyan
Write-Host "  脚本版本: $Script:ScriptVersion" -ForegroundColor Cyan
Write-Host "  官方发布页: https://tokeneff.com/usb" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "提示: 本脚本首行注释亦含版本号，可与官网公布的 SHA256 / 变更日志核对。"

# ---------------- 1. 管理员权限自检（自提权） ----------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn '制作 U盘 需要管理员权限，正在请求提权（请在弹出的 UAC 窗口点「是」）...'
    # 自提权重启自身：irm|iex 管道执行时脚本无文件路径，且 PS5.1 下无法可靠取回脚本本文
    # （$MyInvocation.MyInvocation.ScriptContents 在 iex 场景不存在 —— verifier 发现 B4）。
    # 可靠做法：从版本化 URL 重新下载自身落盘，再以管理员身份执行该文件。
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $selfPath = Join-Path $env:TEMP ("usb-" + $Script:ScriptVersion + ".ps1")
        Write-Step '正在重新下载安装器以完成提权 ...'
        try {
            $selfText = Get-WebTextWithRetry -Url $Script:ScriptUrl -TimeoutSec $Script:HttpTimeoutSec
            if ([string]::IsNullOrWhiteSpace($selfText) -or $selfText.Length -lt 1000) {
                throw '下载内容异常（为空或过短）'
            }
            [System.IO.File]::WriteAllText($selfPath, $selfText, (New-Object System.Text.UTF8Encoding($true)))
        } catch {
            Die '自动提权准备失败（重新下载安装器时出错）。' "请改用两段式命令：先 irm $Script:ScriptUrl -OutFile usb.ps1 下载，然后右键「以管理员身份运行 PowerShell」执行。`n详细原因: $($_.Exception.Message)"
        }
    } else {
        $selfPath = $PSCommandPath
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$selfPath`""
        )
    } catch {
        Die '用户取消了管理员授权，无法继续。' '请重新运行，并在 UAC 弹窗中点击「是」。'
    }
    exit 0
}
Write-Ok '已获得管理员权限'

# ---------------- 2. 拉取组件清单 manifest.json ----------------
Write-Step '正在获取组件清单 (manifest.json) ...'
$manifestText = $null
try {
    $manifestText = Get-WebTextWithRetry -Url $Script:ManifestUrl -TimeoutSec $Script:HttpTimeoutSec
} catch {
    Die '无法下载组件清单。' "请检查网络连接后重试；若多次失败，请访问 https://tokeneff.com/usb 查看服务公告。`n详细原因: $($_.Exception.Message)"
}
try {
    $manifest = $manifestText | ConvertFrom-Json
    if (-not $manifest.components -or $manifest.components.Count -eq 0) { throw 'manifest 缺少 components 数组' }
} catch {
    Die '组件清单解析失败（服务器返回内容异常）。' "请稍后重试；若持续失败请联系客服并提供脚本版本 $Script:ScriptVersion。`n详细原因: $($_.Exception.Message)"
}
Write-Ok "组件清单获取成功（清单版本: $($manifest.version)，生成时间: $($manifest.generated)）"

function Get-Component([string]$Name) {
    $c = $manifest.components | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $c) { throw "manifest 中缺少必需组件: $Name" }
    return $c
}

# ---------------- 3. 枚举 USB 磁盘（硬过滤系统盘/固定盘） ----------------
Write-Step '正在检测已插入的 U盘 ...'
# 只取 BusType=USB 的物理磁盘 —— 硬过滤：系统盘、内置 NVMe/SATA 固定盘一律不列出（§2.5.3-2 双保险）
$usbDisks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
if (-not $usbDisks -or $usbDisks.Count -eq 0) {
    Die '未检测到 U盘。' '请插入容量 ≥64GB 的 U盘 后重新运行本脚本。'
}

Write-Host ""
Write-Host '检测到以下 USB 磁盘：' -ForegroundColor White
$i = 1
$choices = @{}
foreach ($d in $usbDisks) {
    $sizeGB = [math]::Round($d.Size / 1GB, 1)
    Write-Host ("  [{0}] 磁盘 {1}  |  {2}  |  {3} GB" -f $i, $d.Number, $d.FriendlyName, $sizeGB)
    $choices[$i] = $d
    $i++
}
Write-Host ""
# 单候选也需用户确认一次（防误写唯一确认点，§2.5.3-2）
$sel = Read-Host "请输入要制作的 U盘 编号（1-$($usbDisks.Count)）"
$selNum = 0
if (-not [int]::TryParse($sel, [ref]$selNum) -or -not $choices.ContainsKey($selNum)) {
    Die '输入的编号无效。' '请重新运行并输入列表中的数字编号。'
}
$targetDisk = $choices[$selNum]
$sizeGB = [math]::Round($targetDisk.Size / 1GB, 1)

if ($targetDisk.Size -lt ($Script:MinDiskGB * 1GB)) {
    Die "所选 U盘 容量 ${sizeGB} GB，小于最低要求 $Script:MinDiskGB GB。" '请更换容量 ≥64GB（推荐 128GB）的 U盘 后重新运行。'
}

# ---------------- 4. 毁盘警告 + YES 确认 ----------------
Write-Host ""
Write-Host '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' -ForegroundColor Red
Write-Host '  严重警告：制作过程将清空该 U盘 上的全部数据！' -ForegroundColor Red
Write-Host ("  目标: 磁盘 {0}  |  {1}  |  {2} GB" -f $targetDisk.Number, $targetDisk.FriendlyName, $sizeGB) -ForegroundColor Red
Write-Host '  该操作不可恢复，请先备份 U盘 中的重要文件。' -ForegroundColor Red
Write-Host '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' -ForegroundColor Red
$confirm = Read-Host '确认继续请输入大写 YES'
if ($confirm -ne 'YES') { Write-Host '已取消，未对 U盘 做任何修改。'; exit 0 }

# ---------------- 5. Win ISO 选择（默认全选推荐，可跳过） ----------------
Write-Step 'Windows 安装镜像选择'
Write-Host '制作器将从微软官方服务器下载 Windows 安装镜像（推荐，装机必备）。'
Write-Host '  [1] Win10 + Win11 都下载（推荐）'
Write-Host '  [2] 仅 Win11'
Write-Host '  [3] 仅 Win10'
Write-Host '  [4] 跳过（稍后可手动从微软官网下载拷入 U盘 ISO 目录）'
$isoChoice = Read-Host '请选择（直接回车 = 1 推荐）'
if ([string]::IsNullOrWhiteSpace($isoChoice)) { $isoChoice = '1' }
$wantWin10 = ($isoChoice -in '1','3')
$wantWin11 = ($isoChoice -in '1','2')

# ---------------- 6. 准备工作目录并下载自产组件 ----------------
Write-Step '开始下载组件（使用 BITS 后台传输，支持断点续传）...'
New-Item -ItemType Directory -Force -Path $Script:WorkDir | Out-Null
$downloads = @{}   # name -> 本地路径

$selfMadeNames = @('ventoy', 'ai-repair-live', 'winpe', 'memtest86+')
foreach ($name in $selfMadeNames) {
    try {
        $c = Get-Component $name
        $dest = Join-Path $Script:WorkDir $c.filename
        Get-FileViaBits -Url $c.url -Dest $dest -DisplayName "$($c.name) ($($c.filename))"
        Test-FileSha256 -Path $dest -Expected $c.sha256 -DisplayName $c.filename
        $downloads[$name] = $dest
    } catch {
        Die "组件 $name 下载/校验失败。" "请检查网络后重新运行。详细原因: $($_.Exception.Message)"
    }
}

# ---------------- 7. Win10/Win11 ISO：Fido 式官方动态解析 ----------------
# 实现说明（§2.5.3-4 / 风险表 Fido 行）：参考 Fido 项目思路（GPL-3.0，不内嵌其代码），
# 自行实现微软公开下载页的两步流程：① 请求 software-download 页面建立会话并提取
# 产品/会话参数 ② 用会话换取有时效的真实下载直链（文件始终从微软服务器下载，
# 本项目不分发微软任何字节）。微软可能随时调整页面结构 → 解析失败时给兜底指引。
function Get-MsIsoUrl([string]$ProductPageUrl, [string]$EditionKeyword) {
    # 第一步：建立会话，取下载页 HTML
    $session = $null
    $page = $null
    for ($i = 1; $i -le $Script:BitsMaxRetry; $i++) {
        try {
            $page = Invoke-WebRequest -Uri $ProductPageUrl -UseBasicParsing `
                -WebSession ([ref]$session).Value -TimeoutSec $Script:HttpTimeoutSec `
                -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -SessionVariable session
            break
        } catch {
            if ($i -eq $Script:BitsMaxRetry) { throw "无法访问微软下载页: $($_.Exception.Message)" }
            Start-Sleep -Seconds (2 * $i)
        }
    }
    # 第二步：从页面提取会话参数并换取直链。
    # TODO(K0/P8): 微软下载页结构以实测为准 —— 需抓取 product-edition id、
    # sku 换取接口（api/product/...）与最终 DownloadUrl。微软改页面结构时此处需同步更新，
    # 解析失败会走兜底提示，不影响其余组件制作。
    $html = $page.Content
    $m = [regex]::Match($html, 'option value="(?<id>\d+)"[^>]*>\s*' + [regex]::Escape($EditionKeyword))
    if (-not $m.Success) { throw '未能从微软下载页解析出版本选项（页面结构可能已变更）' }
    $productEditionId = $m.Groups['id'].Value

    $skuBody = @{ sessionId = [guid]::NewGuid().ToString(); productEditionId = $productEditionId; sku = ''; language = 'Chinese (Simplified)'; friendlyName = '' } | ConvertTo-Json
    # TODO(K0/P8): 上述请求字段名需对照微软实时接口实测修正（参考 Fido 思路自行实现）
    throw '微软直链接口字段待 K0/P8 实测确认（设计占位：禁止静默产出错误链接）'
}

$winIsoLocal = @{}
foreach ($win in @(@{key='win10'; flag=$wantWin10; name='Windows 10'}, @{key='win11'; flag=$wantWin11; name='Windows 11'})) {
    if (-not $win.flag) { continue }
    $c = $manifest.components | Where-Object { $_.name -eq $win.key } | Select-Object -First 1
    if ($null -eq $c) { Write-Warn "manifest 中无 $($win.key) 条目，跳过"; continue }
    Write-Host "    正在向微软服务器请求 $($win.name) 官方下载直链 ..."
    try {
        $url = Get-MsIsoUrl -ProductPageUrl $c.sourceUrl -EditionKeyword $c.editionKeyword
        $dest = Join-Path $Script:WorkDir $c.filename
        Get-FileViaBits -Url $url -Dest $dest -DisplayName "$($win.name) 官方 ISO"
        Test-FileSha256 -Path $dest -Expected $c.sha256 -DisplayName $c.filename
        $winIsoLocal[$win.key] = $dest
    } catch {
        Write-Warn "获取 $($win.name) 官方下载链接失败: $($_.Exception.Message)"
        Write-Warn '兜底方案: 制作完成后可手动从微软官网下载 ISO，拷入 U盘 ISO 目录即可使用。'
        Write-Host '      微软官方下载: https://www.microsoft.com/zh-cn/software-download/' -ForegroundColor Yellow
    }
}

# ---------------- 8. 解压 Ventoy 包，无人值守写入 ----------------
Write-Step '正在将 Ventoy 引导层写入 U盘（此步骤将重建分区）...'
$ventoyZip = $downloads['ventoy']
$ventoyDir = Join-Path $Script:WorkDir 'ventoy-extracted'
if (Test-Path $ventoyDir) { Remove-Item $ventoyDir -Recurse -Force }
Expand-Archive -Path $ventoyZip -DestinationPath $ventoyDir -Force
$ventoyExe = Get-ChildItem -Path $ventoyDir -Recurse -Filter 'Ventoy2Disk.exe' | Select-Object -First 1
if ($null -eq $ventoyExe) { Die 'Ventoy 包内未找到 Ventoy2Disk.exe。' 'manifest 指向的 Ventoy 包可能损坏，请联系客服。' }

$ventoyArgs = $Script:VentoyExeArgsTemplate `
    -replace '\{DRIVE\}', $targetDisk.Number `
    -replace '\{RESERVE_MB\}', $Script:VentoyReserveMB
Write-Host "    执行: Ventoy2Disk.exe $ventoyArgs"
$proc = Start-Process -FilePath $ventoyExe.FullName -ArgumentList $ventoyArgs -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {   # TODO(K0): 以实测返回码为准
    Die "Ventoy 写入失败（退出码 $($proc.ExitCode)）。" '请重新插拔 U盘后重试；若反复失败请换一只 U盘。'
}
Write-Ok 'Ventoy 引导层写入完成'

# ---------------- 9. 挂载数据分区，拷入 ISO / ventoy.json / config 骨架 ----------------
Write-Step '正在拷入系统镜像与配置 ...'
Start-Sleep -Seconds 3   # 等分区刷新
$targetDisk | Update-Disk -ErrorAction SilentlyContinue

$dataPart = Get-Partition -DiskNumber $targetDisk.Number |
    Where-Object { $_.Type -ne 'Reserved' -and $_.Size -gt 1GB } |
    Sort-Object Size -Descending | Select-Object -First 1
if ($null -eq $dataPart) { Die '未找到 U盘 数据分区。' 'Ventoy 写入异常，请重新运行。' }
if (-not $dataPart.DriveLetter) {
    $freeLetter = (69..90 | ForEach-Object { [char]$_ } | Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1)
    $dataPart | Set-Partition -NewDriveLetter $freeLetter
    $dataPart = Get-Partition -DiskNumber $targetDisk.Number -PartitionNumber $dataPart.PartitionNumber
}
$root = "$($dataPart.DriveLetter):\"
Write-Ok "数据分区已挂载: $root"

New-Item -ItemType Directory -Force -Path (Join-Path $root 'ISO') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'ventoy') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'config') | Out-Null

# 拷入自产 ISO
Copy-Item $downloads['ai-repair-live'] -Destination (Join-Path $root 'ISO') -Force
Copy-Item $downloads['winpe']          -Destination (Join-Path $root 'ISO') -Force
Copy-Item $downloads['memtest86+']     -Destination (Join-Path $root 'ISO') -Force
foreach ($k in $winIsoLocal.Keys) { Copy-Item $winIsoLocal[$k] -Destination (Join-Path $root 'ISO') -Force }

# ventoy.json：默认启动 AI-Repair-Live、菜单超时 3 秒、中文菜单别名（与 make-usb.sh 生成逻辑一致）
$liveFile = (Get-Component 'ai-repair-live').filename
$ventoyJson = @{
    control = @(
        @{ VTOY_DEFAULT_MENU_MODE = '0' }
        @{ VTOY_MENU_TIMEOUT = '3' }
        @{ VTOY_DEFAULT_IMAGE = "/ISO/$liveFile" }
    )
    boot_menu_alias = @(
        @{ image = "/ISO/$liveFile"; alias = 'AI 电脑维修助手（推荐）' }
        @{ image = '/ISO/WinPE_x64.iso'; alias = 'WinPE 装机维护环境' }
        @{ image = '/ISO/MemTest86+.iso'; alias = 'MemTest86+ 内存检测' }
    )
} | ConvertTo-Json -Depth 5
Set-Content -Path (Join-Path $root 'ventoy\ventoy.json') -Value $ventoyJson -Encoding UTF8

# config 骨架：Claude Code 配置与凭证占位（§2.2.4，token 由用户首次使用时自行写入）
Set-Content -Path (Join-Path $root 'config\README.txt') -Encoding UTF8 -Value @"
AI 电脑维修 U盘 配置目录
- auth_token: 首次使用时由维修助手引导您创建，存放网关访问凭证
- 请勿手动删除本目录
"@
Write-Ok '镜像与配置拷入完成'

# ---------------- 10. 逐文件 SHA256 复核（盘上文件重读校验，§2.5.3-6） ----------------
Write-Step '正在做最终校验 ...'
foreach ($name in $selfMadeNames) {
    $c = Get-Component $name
    if ($name -eq 'ventoy') { continue }   # ventoy 包本身已解压写入，不重复校验
    Test-FileSha256 -Path (Join-Path $root ('ISO\' + $c.filename)) -Expected $c.sha256 -DisplayName $c.filename
}
foreach ($k in $winIsoLocal.Keys) {
    $c = $manifest.components | Where-Object { $_.name -eq $k } | Select-Object -First 1
    Test-FileSha256 -Path (Join-Path $root ('ISO\' + $c.filename)) -Expected $c.sha256 -DisplayName $c.filename
}

# ---------------- 11. 完成 ----------------
Write-Host ""
Write-Host '===============================================' -ForegroundColor Green
Write-Host '  制作完成，可以拔下使用了！' -ForegroundColor Green
Write-Host '===============================================' -ForegroundColor Green
Write-Host ''
Write-Host '使用方法: 将 U盘 插入需要维修的电脑 → 开机按启动菜单键(F12/F9/Esc) → 选择 U盘 启动'
if ($wantWin10 -or $wantWin11) {
    if ($winIsoLocal.Count -lt ([int]$wantWin10 + [int]$wantWin11)) {
        Write-Warn '部分 Windows 镜像未能自动下载，请从微软官网手动下载后拷入 U盘 ISO 目录。'
    }
}
Write-Host ''
$eject = Read-Host '是否现在安全弹出 U盘？（y/N）'
if ($eject -eq 'y' -or $eject -eq 'Y') {
    try {
        $vol = Get-Volume -DriveLetter $dataPart.DriveLetter
        $vol | Get-Partition | Get-Disk | Set-Disk -IsOffline $true
        Write-Ok 'U盘 已安全弹出，可以拔下。'
    } catch { Write-Warn '自动弹出失败，请使用系统托盘「安全删除硬件」手动弹出。' }
}
Read-Host '按回车键退出'
