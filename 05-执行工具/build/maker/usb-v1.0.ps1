# usb-v1.0.ps1 版本: 1.0.0  (AI 电脑维修 U盘 一键制作器 · Windows 端)
# =====================================================================
# 创建日期: 2026-09-12
# 版本: 1.0.0
# 状态: 草稿（Ventoy CLI 参数待 K0 实测后定稿，见下方 TODO(K0)）
# 兼容: PowerShell 5.1+（Win10/Win11 自带，不依赖第三方工具）
# 设计依据: 技术方案_AI电脑维修U盘_总体设计_20260912.md §2.5
# 用法（官网一键命令）:
#   irm https://usb.tokeneff.com/maker/usb-v1.0.ps1 | iex
# 审阅后再执行（推荐给维修人员）:
#   irm https://usb.tokeneff.com/maker/usb-v1.0.ps1 -OutFile usb.ps1
#   notepad usb.ps1            # 审阅
#   powershell -ExecutionPolicy Bypass -File .\usb.ps1
# =====================================================================

#requires -Version 5.1

# 控制台 UTF-8（中文输出兜底；irm 下载乱码的根治在服务端 charset 响应头）
try {
    $OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    chcp 65001 > $null
} catch { }

# ---------------- 全局常量（集中定义，改这里即可） ----------------
$Script:ScriptVersion   = '1.1.0'
$Script:ScriptUrl       = 'https://usb.tokeneff.com/maker/usb-v1.0.ps1'      # 自提权时按版本化 URL 重新下载自身（见下）
$Script:ManifestUrl     = 'https://usb.tokeneff.com/maker/manifest.json'   # TODO(发布): 迁移到独立 CDN 域名（§2.5.4 故障隔离）
$Script:MinDiskGB       = 8     # 安装实际所需：Ventoy + 1.4GB 维修 ISO + ~6GB Windows ISO ≈ 8GB；不设高门槛，减少用户心智消耗
$Script:HttpTimeoutSec  = 30        # manifest / 小请求超时
$Script:PortalApiBase   = 'https://tokeneff.com/api/usb'   # 制作时签发 USB token 的 portal 接口前缀（换域名改这里）
$Script:BitsMaxRetry    = 3         # 所有网络操作统一重试次数
$Script:WorkDir         = Join-Path $env:TEMP 'ai-repair-usb-maker'

# ---- 场景③便携运行时（v0.2 决策：U盘 bin\ 内置，任意 Windows 免安装直跑）----
# Claude Code 官方 GCS 分发桶：/stable → 最新版本号；/<ver>/manifest.json → win32-x64 sha256
$Script:ClaudeGcsBase   = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
# 便携 Git（Claude Code Bash 工具依赖，含 bin\bash.exe）：自托管重打包
# （官方 PortableGit SFX 解出后重打为 zip，跨平台可解），固定 sha256；升级 = 换 URL+哈希
$Script:PortableGitUrl    = 'https://usb.tokeneff.com/downloads/PortableGit-2.56.0.2-64-bit.zip'
$Script:PortableGitSha256 = '8e4cb757edb480c6e94ff3858352c2ea1e431cf5bc15d5df3fd56e2904c18dab'

# ---- Ventoy 官方直链动态解析（manifest url 为空时的兜底，§2.5.3-4）----
# 固定版本号 + 多源候选（GitHub 官方 → 国内加速镜像），发布升级改这里即可。
$Script:VentoyVersion = '1.1.18'
$Script:VentoyAsset  = "ventoy-$($Script:VentoyVersion)-windows.zip"
$Script:VentoyUrlBase = "https://github.com/ventoy/Ventoy/releases/download/v$($Script:VentoyVersion)/$($Script:VentoyAsset)"
$Script:VentoyUrlCandidates = @(
    $Script:VentoyUrlBase,
    "https://gh-proxy.com/$Script:VentoyUrlBase",
    "https://ghfast.top/$Script:VentoyUrlBase"
)

# ---- Ventoy CLI 官方语法（https://www.ventoy.net/en/doc_windows_cli.html，v1.0.86+）----
# Ventoy2Disk.exe VTOYCLI /I /PhyDrive:<盘号> [/GPT] [/R:<保留MB>]  安装（重建分区，清盘）
# Ventoy2Disk.exe VTOYCLI /U /PhyDrive:<盘号>                      升级（已有 Ventoy 时，保留数据分区文件）
# 进度/结果回报：运行目录下 cli_percent.txt（0-100）与 cli_done.txt（0=成功 1=失败），无控制台输出。
# 2026-10-14 K0 实测教训：错误的参数组合会静默退回 GUI 模式，关窗退出码非 0 → 误报失败。必须用 VTOYCLI 前缀。
$Script:VentoyReserveMB = 2048   # 盘尾保留空间（供 Live 持久化/日志扩展）

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

# 就地刷新的单行文本进度条（百分比 / 已传 / 总量 / 速度 / 剩余时间）
function Show-ProgressBar([double]$Fraction, [string]$DoneText, [string]$TotalText, [string]$SpeedText, [string]$EtaText) {
    if ($Fraction -lt 0) { $Fraction = 0 }; if ($Fraction -gt 1) { $Fraction = 1 }
    $width = 30; $filled = [int][math]::Floor($Fraction * $width)
    $bar = ('#' * $filled) + ('.' * ($width - $filled))
    $line = ("    [{0}] {1,3:0}%  {2} / {3}  {4}  剩余 {5} " -f $bar, ($Fraction * 100), $DoneText, $TotalText, $SpeedText, $EtaText)
    Write-Host "`r$line" -NoNewline
}

# BITS 下载大文件 + 重试 + 实时进度（§2.5.3 指定 BITS，不自研分块并行）
function Get-FileViaBits([string]$Url, [string]$Dest, [string]$DisplayName) {
    # 实现说明：原设计用 BITS，但实测部分 Windows 的 BitsTransfer 模块无 -AsJob 参数（2026-10-14 K0），
    # 改用 HttpWebRequest 流式下载（全版本通用）+ Range 断点续传（服务端 nginx 已验证支持）。
    $lastErr = $null
    for ($i = 1; $i -le $Script:BitsMaxRetry; $i++) {
        try {
            Write-Host "    下载 $DisplayName（第 $i/$Script:BitsMaxRetry 次尝试）..."
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.UserAgent = "ai-repair-usb-maker/$Script:ScriptVersion"
            $req.Timeout = 30000; $req.ReadWriteTimeout = 60000
            # 断点续传：已有部分文件则从断点继续
            $existing = 0L
            if (Test-Path $Dest) { $existing = (Get-Item $Dest).Length }
            if ($existing -gt 0) {
                $req.AddRange($existing)
                Write-Host ("    检测到未完成文件，从 {0:N1}MB 处续传..." -f ($existing / 1MB)) -ForegroundColor DarkGray
            }
            $resp = $req.GetResponse()
            $httpCode = [int]$resp.StatusCode
            # 206=续传成功；200=服务端不支持 Range（从头下载）
            if ($existing -gt 0 -and $httpCode -eq 200) { $existing = 0 }   # 服务端忽略了 Range，重头下
            $total = $resp.ContentLength
            if ($existing -gt 0 -and $httpCode -eq 206) { $total += $existing }
            $in = $resp.GetResponseStream()
            $mode = if ($existing -gt 0 -and $httpCode -eq 206) { 'Append' } else { 'Create' }
            $out = New-Object System.IO.FileStream($Dest, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write)
            if ($mode -eq 'Append') { $out.Seek(0, 'End') | Out-Null } else { $out.SetLength(0) }
            $buf = New-Object byte[] 262144
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $lastTick = $sw.Elapsed.TotalSeconds; $lastBytes = $existing; $done = $existing
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                $now = $sw.Elapsed.TotalSeconds
                if ($total -gt 0 -and ($now - $lastTick) -ge 0.5) {
                    $speed = ($done - $lastBytes) / ($now - $lastTick)
                    if (($now - $lastTick) -ge 2) { $lastBytes = $done; $lastTick = $now }
                    $remainMB = ($total - $done) / 1MB
                    $eta = if ($speed -gt 1) { [int][math]::Ceiling($remainMB * 1MB / $speed) } else { -1 }
                    $etaText = if ($eta -ge 0) { "{0:mm\分ss\秒}" -f [TimeSpan]::FromSeconds($eta) } else { '--' }
                    Show-ProgressBar ($done / $total) ("{0:N1}MB" -f ($done / 1MB)) ("{0:N1}MB" -f ($total / 1MB)) ("{0:N1}MB/s" -f ($speed / 1MB)) $etaText
                }
            }
            $out.Flush(); $out.Close(); $in.Close(); $resp.Close()
            if ($total -gt 0 -and $done -lt $total) { throw "连接中断（$done / $total 字节），下次运行将自动续传" }
            Write-Host "`r" -NoNewline
            Write-Host ("    {0} 下载完成（{1:N1}MB）" -f $DisplayName, ($done / 1MB))
            return
        } catch {
            # PS 5.1 会把 .NET 方法异常包成 MethodInvocationException，真异常在 InnerException
            $ex = $_.Exception
            if ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
            # 416 Range Not Satisfiable：断点已到文件尾 = 之前已下载完成，直接成功返回（随后有 SHA256 兜底校验）
            if ($ex -is [System.Net.WebException] -and $ex.Response -and
                [int]$ex.Response.StatusCode -eq 416) { return }
            $lastErr = $_
            Write-Warn "$DisplayName 下载失败: $($_.Exception.Message)"
            if ($i -lt $Script:BitsMaxRetry) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    throw "下载多次失败: $DisplayName （$($lastErr.Exception.Message)）"
}

# robocopy 拷贝：robocopy 自带按字节百分比进度（大文件拷入U盘用；退出码 0-7 均为成功）
function Copy-FileWithProgress([string]$Path, [string]$DestDir) {
    $name = Split-Path $Path -Leaf
    Write-Host "    拷入 $name ..."
    robocopy (Split-Path $Path -Parent) $DestDir $name /NJH /NJS /NDL /MT:4
    if ($LASTEXITCODE -ge 8) { throw "robocopy 拷贝失败（退出码 $LASTEXITCODE）: $name" }
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

# ---------------- 制作时签发 USB token（可选，可跳过；幂等） ----------------

# 向 portal 提交 JSON POST，成功返回解析后的对象；失败抛异常（含服务端错误信息）
function Invoke-PortalJson([string]$Path, [string]$Body) {
    $req = [System.Net.HttpWebRequest]::Create($Script:PortalApiBase + $Path)
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    # portal 网关中间件要求 POST 带 AJAX 标识头（2026-10-14 实测缺头 403）
    $req.Headers.Add('X-Requested-With', 'XMLHttpRequest')
    $req.Timeout = $Script:HttpTimeoutSec * 1000
    $req.UserAgent = "ai-repair-usb-maker/$Script:ScriptVersion"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $req.ContentLength = $bytes.Length
    $rs = $req.GetRequestStream()
    $rs.Write($bytes, 0, $bytes.Length)
    $rs.Close()
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        # 4xx（如验证码错误）带错误体：读出服务端 message 再抛，便于用户理解
        if ($_.Exception.Response) {
            $esr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $errText = $esr.ReadToEnd()
            $esr.Close()
            throw "服务端返回错误: $errText"
        }
        throw
    }
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    $sr.Close(); $resp.Close()
    return ($text | ConvertFrom-Json)
}

# 邮箱验证 → 签发 USB token → 写入 U盘 config\auth_token（UTF-8 无 BOM 无换行）
# 任何失败都不阻塞制作流程：提示开机后系统内会再引导配置（welcome.sh 保留手输兜底）
function Initialize-UsbToken([string]$Root) {
    $tokenFile = Join-Path $Root 'config\auth_token'
    if ((Test-Path $tokenFile) -and -not [string]::IsNullOrWhiteSpace((Get-Content $tokenFile -Raw))) {
        Write-Ok '检测到已有 AI 服务凭证（config\auth_token），跳过配置'
        return
    }
    Write-Host ''
    $ans = Read-Host '是否现在配置 AI 服务（免费，只需邮箱验证）？（y/N）'
    if ($ans -ne 'y' -and $ans -ne 'Y') {
        Write-Warn '已跳过。开机进入维修系统后也会引导您完成配置。'
        return
    }
    # 首次 + 最多 2 次重试；仍失败不阻塞制作
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $email = Read-Host '请输入邮箱'
            if ([string]::IsNullOrWhiteSpace($email)) { throw '邮箱不能为空' }
            Invoke-PortalJson -Path '/activate/request-code' -Body (@{ email = $email } | ConvertTo-Json) | Out-Null
            Write-Ok "验证码已发送到邮箱（10 分钟内有效）"
            $code = Read-Host '请输入邮箱收到的 6 位验证码'
            if ($code -notmatch '^\d{6}$') { throw '验证码应为 6 位数字' }
            # v0.3.1：顺手设置登录密码 → 用户可凭邮箱+密码登录 tokeneff.com 查余额/管理 Key。
            # PS 5.1 的 Read-Host 无 -Mask 参数，密码会回显——用户自己机器上可接受。
            Write-Host '    提示：若该邮箱已注册过官网账号，此密码将同步修改其登录密码。' -ForegroundColor Yellow
            $pwd1 = Read-Host '设置登录密码（至少 8 位，登录官网 tokeneff.com 查余额用；直接回车跳过）'
            if (-not [string]::IsNullOrWhiteSpace($pwd1)) {
                if ($pwd1.Length -lt 8) { throw '密码至少 8 位' }
                $pwd2 = Read-Host '请再次输入密码'
                if ($pwd1 -ne $pwd2) { throw '两次输入的密码不一致' }
            } else { $pwd1 = $null }
            $verifyBody = @{ email = $email; code = $code }
            if ($pwd1) { $verifyBody.password = $pwd1 }
            $resp = Invoke-PortalJson -Path '/activate/verify' -Body ($verifyBody | ConvertTo-Json)
            $tok = $resp.token
            if (-not $tok) { $tok = $resp.usb_token }   # 兼容字段名差异（token / usb_token）
            if (-not $tok) { throw '服务器未返回 token' }
            # UTF-8 无 BOM、无换行写入（Set-Content 在 5.1 下必带 BOM 或换行，故用 WriteAllText）
            [System.IO.File]::WriteAllText($tokenFile, "$tok", (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok 'AI 服务凭证已写入 U盘（config\auth_token），开机后可直接使用'
            return
        } catch {
            Write-Warn "配置失败（第 $attempt 次尝试）: $($_.Exception.Message)"
            if ($attempt -lt 3) {
                $retry = Read-Host '是否重试？（Y/n）'
                if ($retry -eq 'n' -or $retry -eq 'N') { break }
            }
        }
    }
    Write-Warn '未完成 AI 服务配置。不影响 U盘 制作——开机进入维修系统后会再引导您配置。'
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
$usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })
if ($usbDisks.Count -eq 0) {
    Die '未检测到 U盘。' '请插入容量 ≥8GB 的 U盘 后重新运行本脚本。'
}
# 候选 = 满足容量要求的 USB 磁盘；不达标的（读卡器/加密狗等小存储）提示后忽略
$candidates = @($usbDisks | Where-Object { $_.Size -ge ($Script:MinDiskGB * 1GB) })
foreach ($d in ($usbDisks | Where-Object { $_.Size -lt ($Script:MinDiskGB * 1GB) })) {
    Write-Host ("  已忽略磁盘 {0}（{1}，容量不足 {2} GB，非制作目标）" -f $d.Number, $d.FriendlyName, [math]::Round($d.Size / 1GB, 1)) -ForegroundColor DarkGray
}

Write-Host ""
if ($candidates.Count -eq 0) {
    Die "所有 USB 磁盘容量均不足 $Script:MinDiskGB GB。" '请更换容量 ≥8GB（推荐 128GB）的 U盘 后重新运行。'
} elseif ($candidates.Count -eq 1) {
    # 唯一合格 U盘 → 自动选中，免除编号输入（防误写由下方整盘清空 YES 确认兜底，§2.5.3-2）
    $targetDisk = $candidates[0]
    $sizeGB = [math]::Round($targetDisk.Size / 1GB, 1)
    Write-Host ("检测到唯一合格 U盘，已自动选中：磁盘 {0}  |  {1}  |  {2} GB" -f $targetDisk.Number, $targetDisk.FriendlyName, $sizeGB) -ForegroundColor Green
} else {
    # 多只合格 U盘 → 必须人工指定（自动选择无从判断用户意图）
    Write-Host '检测到多只合格 U盘，请输入要制作的那只的编号：' -ForegroundColor White
    for ($k = 0; $k -lt $candidates.Count; $k++) {
        $d = $candidates[$k]
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        Write-Host ("  [{0}] 磁盘 {1}  |  {2}  |  {3} GB" -f ($k + 1), $d.Number, $d.FriendlyName, $sizeGB)
    }
    Write-Host ""
    $sel = Read-Host "请输入要制作的 U盘 编号（1-$($candidates.Count)）"
    $selNum = 0
    if (-not [int]::TryParse($sel, [ref]$selNum) -or $selNum -lt 1 -or $selNum -gt $candidates.Count) {
        Die '输入的编号无效。' '请重新运行并输入列表中的数字编号。'
    }
    $targetDisk = $candidates[$selNum - 1]
}
$sizeGB = [math]::Round($targetDisk.Size / 1GB, 1)

if ($targetDisk.Size -lt ($Script:MinDiskGB * 1GB)) {
    Die "所选 U盘 容量 ${sizeGB} GB，小于最低要求 $Script:MinDiskGB GB。" '请更换容量 ≥8GB（推荐 128GB）的 U盘 后重新运行。'
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
Write-Step '开始下载组件（支持断点续传 + 实时进度）...'
New-Item -ItemType Directory -Force -Path $Script:WorkDir | Out-Null
$downloads = @{}   # name -> 本地路径

$selfMadeNames = @('ventoy', 'ai-repair-live', 'winpe', 'memtest86+')
foreach ($name in $selfMadeNames) {
    try {
        $c = Get-Component $name

        # —— 空 URL 分流 ——
        # ventoy：manifest 未发布托管 → 动态解析 Ventoy 官方直链（GitHub + 国内镜像兜底）
        # winpe / memtest86+：本项目自产组件尚未发布（P4.5 后填充）→ 警告跳过，不阻断制作
        if ([string]::IsNullOrWhiteSpace($c.url) -and $name -eq 'ventoy') {
            $url = $null
            foreach ($u in $Script:VentoyUrlCandidates) {
                try {
                    Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec $Script:HttpTimeoutSec | Out-Null
                    $url = $u; break
                } catch { }
            }
            if (-not $url) { throw "Ventoy v$($Script:VentoyVersion) 官方直链与镜像均不可达" }
            $c.filename = $Script:VentoyAsset
            $c.sha256 = ''   # 官方包无固定哈希，跳过校验（来源 = github.com/ventoy 官方 Release）
            Write-Host ("  Ventoy 直链解析成功（v{0}，源: {1}）" -f $Script:VentoyVersion, ([uri]$url).Host) -ForegroundColor DarkGray
        } elseif ([string]::IsNullOrWhiteSpace($c.url)) {
            Write-Warn "组件 $($c.name)（$($c.filename)）尚未发布，本次制作跳过——不影响维修系统主体功能。"
            continue
        } else {
            $url = $c.url
        }

        $dest = Join-Path $Script:WorkDir $c.filename
        Get-FileViaBits -Url $url -Dest $dest -DisplayName "$($c.name) ($($c.filename))"
        Test-FileSha256 -Path $dest -Expected $c.sha256 -DisplayName $c.filename
        $downloads[$name] = $dest
    } catch {
        Die "组件 $name 下载/校验失败。" "请检查网络后重新运行。详细原因: $($_.Exception.Message)"
    }
}

# ---------------- 6.5 场景③便携运行时：claude.exe + MinGit（可选组件，失败不阻断） ----------------
# U盘 bin\ 内置后，任意 Windows 双击 repair-on-windows.bat 免安装直跑；
# 任一下载失败只警告：双击入口自动回落在线安装（方案 5.3 降级链不变）
$Script:ClaudeExeLocal  = $null
$Script:ClaudeExeSha256 = ''
$MinGitLocal = $null
try {
    $claudeVer = (Get-WebTextWithRetry -Url "$($Script:ClaudeGcsBase)/stable" -TimeoutSec $Script:HttpTimeoutSec).Trim()
    $cm = (Get-WebTextWithRetry -Url "$($Script:ClaudeGcsBase)/$claudeVer/manifest.json" -TimeoutSec $Script:HttpTimeoutSec) | ConvertFrom-Json
    $Script:ClaudeExeSha256 = $cm.platforms.'win32-x64'.checksum
    if ([string]::IsNullOrWhiteSpace($Script:ClaudeExeSha256)) { throw 'manifest 缺少 win32-x64 checksum' }
    $claudeDir = Join-Path $Script:WorkDir 'portable-bin'
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    Write-Host "  便携版 claude $claudeVer（win32-x64，约 236MB）..."
    $Script:ClaudeExeLocal = Join-Path $claudeDir 'claude.exe'
    Get-FileViaBits -Url "$($Script:ClaudeGcsBase)/$claudeVer/win32-x64/claude.exe" -Dest $Script:ClaudeExeLocal -DisplayName "claude-portable ($claudeVer)"
    Test-FileSha256 -Path $Script:ClaudeExeLocal -Expected $Script:ClaudeExeSha256 -DisplayName "claude.exe ($claudeVer)"
    Write-Ok "便携版 claude.exe 就绪（$claudeVer，官方 sha256 校验通过）"
} catch {
    Write-Warn "便携版 claude.exe 获取失败（$($_.Exception.Message)）。不阻断制作——场景③双击入口将回落为在线安装。"
    $Script:ClaudeExeLocal = $null
}
try {
    $pgDir = Join-Path $Script:WorkDir 'portable-bin'
    New-Item -ItemType Directory -Force -Path $pgDir | Out-Null
    Write-Host '  便携 Git（Bash 工具依赖，约 154MB）...'
    $MinGitLocal = Join-Path $pgDir 'PortableGit.zip'
    Get-FileViaBits -Url $Script:PortableGitUrl -Dest $MinGitLocal -DisplayName 'PortableGit-2.56.0.2-64-bit.zip'
    Test-FileSha256 -Path $MinGitLocal -Expected $Script:PortableGitSha256 -DisplayName 'PortableGit-2.56.0.2-64-bit.zip'
    Write-Ok '便携 Git 就绪（2.56.0.2，自托管 sha256 校验通过）'
} catch {
    Write-Warn "便携 Git 获取失败（$($_.Exception.Message)）。不阻断制作——目标电脑已装 Git 时不受影响，未装则 Bash 工具受限。"
    $MinGitLocal = $null
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

# ---------------- 8. 解压 Ventoy 包，CLI 无人值守写入 ----------------
Write-Step '正在将 Ventoy 引导层写入 U盘...'
$ventoyZip = $downloads['ventoy']
$ventoyDir = Join-Path $Script:WorkDir 'ventoy-extracted'
if (Test-Path $ventoyDir) { Remove-Item $ventoyDir -Recurse -Force }
Expand-Archive -Path $ventoyZip -DestinationPath $ventoyDir -Force
$ventoyExe = Get-ChildItem -Path $ventoyDir -Recurse -Filter 'Ventoy2Disk.exe' | Select-Object -First 1
if ($null -eq $ventoyExe) { Die 'Ventoy 包内未找到 Ventoy2Disk.exe。' 'manifest 指向的 Ventoy 包可能损坏，请联系客服。' }

# 已装 Ventoy → /U 无损升级（数据分区文件与 ISO 全部保留）；未装 → /I 全新安装（重建分区，GPT + 盘尾保留）
$hasVentoy = [bool](Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue |
    Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.FileSystemLabel -eq 'Ventoy' })
if ($hasVentoy) {
    Write-Warn '检测到 U盘已安装 Ventoy → 执行无损升级（盘中已有文件与 ISO 将全部保留）'
    $ventoyArgs = "VTOYCLI /U /PhyDrive:$($targetDisk.Number)"
} else {
    $ventoyArgs = "VTOYCLI /I /PhyDrive:$($targetDisk.Number) /GPT /R:$($Script:VentoyReserveMB)"
}
Write-Host "    执行: Ventoy2Disk.exe $ventoyArgs"
Write-Host '    正在写入引导层（请勿拔盘）...' -ForegroundColor DarkGray

# Ventoy CLI 无控制台输出：进度写 cli_percent.txt（0-100），结束写 cli_done.txt（0=成功 1=失败），均在运行目录
$exeDir     = $ventoyExe.DirectoryName
$cliPercent = Join-Path $exeDir 'cli_percent.txt'
$cliDone    = Join-Path $exeDir 'cli_done.txt'
Remove-Item $cliPercent, $cliDone -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $ventoyExe.FullName -ArgumentList $ventoyArgs -PassThru `
    -WindowStyle Hidden -WorkingDirectory $exeDir
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $proc.HasExited -and -not (Test-Path $cliDone)) {
    Start-Sleep -Milliseconds 400
    $pct  = 0; $tmp = 0
    $raw  = if (Test-Path $cliPercent) { Get-Content $cliPercent -Raw -ErrorAction SilentlyContinue } else { '' }
    if ([int]::TryParse((" $raw" -replace '\D', ''), [ref]$tmp) -and $tmp -le 100) { $pct = $tmp }
    $barW = 24; $fill = [int]([math]::Floor($pct / 100.0 * $barW))
    $bar  = '#' * $fill + '.' * ($barW - $fill)
    Write-Host ("`r    [{0}] {1,3}%  已用时 {2:mm\分ss\秒} " -f $bar, $pct, $sw.Elapsed) -NoNewline
}
Write-Host ("`r    写入结束，用时 {0:mm\分ss\秒}        " -f $sw.Elapsed)

# 成功判定：官方约定 cli_done.txt 内容 0=成功；文件缺失时回退——全新安装看盘上是否出现 Ventoy 卷，升级看退出码
$ventoyOk = $false
if (Test-Path $cliDone) {
    $ventoyOk = ((Get-Content $cliDone -Raw -ErrorAction SilentlyContinue) -replace '\D', '' -eq '0')
} elseif ($hasVentoy) {
    $ventoyOk = ($proc.ExitCode -eq 0)   # 升级路径盘上本来就有 Ventoy 卷，不能拿卷标当证据
} else {
    Start-Sleep -Seconds 2
    $ventoyOk = [bool](Get-Partition -DiskNumber $targetDisk.Number -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'Ventoy' })
}
if (-not $ventoyOk) {
    $doneTxt = if (Test-Path $cliDone) { (Get-Content $cliDone -Raw) } else { '缺失' }
    Get-Content (Join-Path $exeDir 'cli_log.txt') -ErrorAction SilentlyContinue | Select-Object -Last 10 |
        ForEach-Object { Write-Host "    | $_" -ForegroundColor DarkGray }
    Die "Ventoy 写入失败（cli_done=$($doneTxt.Trim())，退出码 $($proc.ExitCode)）。" '请重新插拔 U盘后重试；若反复失败请换一只 U盘。'
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

# 拷入自产 ISO（robocopy 百分比进度；仅拷实际下载到的组件，未发布的自动跳过）
foreach ($name in $selfMadeNames) {
    if ($name -eq 'ventoy' -or -not $downloads.ContainsKey($name)) { continue }
    Copy-FileWithProgress $downloads[$name] (Join-Path $root 'ISO')
}
foreach ($k in $winIsoLocal.Keys) { Copy-FileWithProgress $winIsoLocal[$k] (Join-Path $root 'ISO') }

# ventoy.json：默认启动 AI-Repair-Live、菜单超时 3 秒、中文菜单别名（与 make-usb.sh 生成逻辑一致）
$liveFile = (Get-Component 'ai-repair-live').filename
$ventoyJson = @{
    control = @(
        @{ VTOY_DEFAULT_MENU_MODE = '0' }
        @{ VTOY_MENU_TIMEOUT = '3' }
        @{ VTOY_MENU_LANGUAGE = 'zh_CN' }   # 启动菜单默认中文；菜单界面按 L 键可随时切换中/英文
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

# 场景③ Windows 在线维修双击入口（repair-on-windows.bat/.ps1，与制作脚本同源同目录；
# WebClient 二进制下载，避免 Set-Content 给 bat 写入 BOM 导致 @echo off 失效）
foreach ($f in @('repair-on-windows.bat', 'repair-on-windows.ps1')) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', "ai-repair-usb-maker/$Script:ScriptVersion")
        $wc.DownloadFile('https://usb.tokeneff.com/maker/' + $f, (Join-Path $root $f))
        Write-Ok "已放入 Windows 在线维修入口: $f"
    } catch {
        Write-Warn "$f 下载失败（Windows 在线维修入口缺失，不影响 U盘 启动维修）。网络恢复后重新制作即可补上。"
    }
}

# 场景③便携运行时 → U盘 bin\（claude.exe 直跑 + MinGit 提供 bash；失败已在上游警告跳过）
if ($Script:ClaudeExeLocal -and (Test-Path $Script:ClaudeExeLocal)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin') | Out-Null
    Copy-FileWithProgress $Script:ClaudeExeLocal (Join-Path $root 'bin')
    Write-Ok '便携版 claude.exe 已放入 U盘 bin\'
}
if ($MinGitLocal -and (Test-Path $MinGitLocal)) {
    $gitDest = Join-Path $root 'bin\PortableGit'
    Write-Host '    解压便携 Git 到 U盘 bin\PortableGit ...'
    Expand-Archive -Path $MinGitLocal -DestinationPath $gitDest -Force
    Write-Ok '便携 Git 已解压到 U盘 bin\PortableGit'
}

# 制作时签发 USB token（可选步骤：邮箱验证 → 写 config\auth_token；可跳过，失败不阻塞）
Initialize-UsbToken -Root $root

Write-Ok '镜像与配置拷入完成'

# ---------------- 10. 逐文件 SHA256 复核（盘上文件重读校验，§2.5.3-6） ----------------
Write-Step '正在做最终校验 ...'
foreach ($name in $selfMadeNames) {
    $c = Get-Component $name
    if ($name -eq 'ventoy') { continue }             # ventoy 包本身已解压写入，不重复校验
    if (-not $downloads.ContainsKey($name)) { continue }   # 未发布组件（winpe/memtest86+）未拷入，跳过
    Test-FileSha256 -Path (Join-Path $root ('ISO\' + $c.filename)) -Expected $c.sha256 -DisplayName $c.filename
}
foreach ($k in $winIsoLocal.Keys) {
    $c = $manifest.components | Where-Object { $_.name -eq $k } | Select-Object -First 1
    Test-FileSha256 -Path (Join-Path $root ('ISO\' + $c.filename)) -Expected $c.sha256 -DisplayName $c.filename
}
# 便携版 claude.exe 盘上重读复核（拷贝过程损坏会导致目标电脑静默回落在线安装，务必校验）
if ($Script:ClaudeExeLocal -and (Test-Path (Join-Path $root 'bin\claude.exe'))) {
    Test-FileSha256 -Path (Join-Path $root 'bin\claude.exe') -Expected $Script:ClaudeExeSha256 -DisplayName 'bin\claude.exe'
}

# ---------------- 11. 完成 ----------------
Write-Host ""
Write-Host '===============================================' -ForegroundColor Green
Write-Host '  制作完成，可以拔下使用了！' -ForegroundColor Green
Write-Host '===============================================' -ForegroundColor Green
Write-Host ''
Write-Host '使用方法: 将 U盘 插入需要维修的电脑 → 开机按启动菜单键(F12/F9/Esc) → 选择 U盘 启动'
if (Test-Path (Join-Path $root 'repair-on-windows.bat')) {
    if (Test-Path (Join-Path $root 'bin\claude.exe')) {
        Write-Host '电脑还能进 Windows 时: 双击 U盘 根目录 repair-on-windows.bat，即可在 Windows 内在线维修（免安装直跑，无需重启）'
    } else {
        Write-Host '电脑还能进 Windows 时: 双击 U盘 根目录 repair-on-windows.bat，即可在 Windows 内在线维修（首次将在线安装 claude）'
    }
}
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
