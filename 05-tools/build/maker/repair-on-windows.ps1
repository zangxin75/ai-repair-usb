# repair-on-windows.ps1 版本: 0.4.0  (AI 电脑维修 U盘 · 场景③ Windows 在线维修启动器)
# =====================================================================
# 创建日期: 2026-10-13
# 版本: 0.4.0（0.2.0 + 模式菜单先于提权：维修模式按需 UAC / 办公助手模式免提权 /
#        Codex CLI 入口按 agents.json 显隐；多Agent工作站 P-A A2）
# 0.4.0（P-B）：+OpenClaw / Pi 入口（便携 Node 运行时 + 自包含预装包，入口直启 node cli；状态目录重定向 U盘）
#        0.2.0（0.1.0 + 便携模式：U盘 bin\claude.exe 优先直跑、免安装；缺失/损坏回落在线安装）
#        0.1.0（W1 骨架 + W2 激活/余额/验证接入，RDD 需求表 R1-R41）
# 状态: 草稿（待 K1a 真机验收；网关 /api/usb/* 按 5.4 契约编码，未上线前靠 mock 驱动）
# 兼容: PowerShell 5.1+（Win10/Win11 自带，不依赖第三方模块）
# 设计依据: 技术方案_AI电脑维修U盘_场景三Windows在线维修新增功能_20261013.md V1.2
#           功能 1/3/4、5.1 settings.conf、5.3 安装失败降级链、5.4 API 契约、5.5 激活接入
#           技术方案_U盘便携多Agent工作站_v1.2_20261015.md §6（启动器多模式）
# 用法: 双击同目录 repair-on-windows.bat（不自动提权，由模式菜单按需触发），或直接运行本 ps1
# =====================================================================

#requires -Version 5.1
param(
    # 防提权循环标记：自提升重入时携带；也用于绕过模式菜单直接进维修流程
    [switch]$Elevated
)

# ---------------- 全局常量（集中定义，改这里即可） ----------------
$Script:ScriptVersion   = '0.4.0'
$Script:HttpTimeoutSec  = 30        # API 请求超时
$Script:NetMaxRetry     = 3         # 网关请求总尝试次数（首次 + 重试 2 次，方案 5.3）
$Script:InstallMaxRetry = 3         # claude 安装总尝试次数（首次 + 重试 2 次，间隔 10s）
$Script:TempRoot        = Join-Path $env:TEMP 'ai-repair'          # 临时工作副本根（%TEMP%\ai-repair\）
$Script:TempClaudeDir   = Join-Path $Script:TempRoot 'claude'      # CLAUDE_CONFIG_DIR 指向（R27）
$Script:ClaudeInstallUrl = 'https://claude.ai/install.ps1'         # 官方安装器唯一渠道（供应链红线）
$Script:UpgradeUrlFile  = 'upgrade-url.txt'                        # U盘根预置升级入口文件（方案 6.4 软着陆）
$Script:DefaultGatewayBase = 'https://tokeneff.com'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------- 工具函数（风格沿用 usb-v1.0.ps1） ----------------

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

# 场景②离线维修引导文案（方案 5.3 兜底：③完全依赖网关，不可用时统一引导离线）
function Show-OfflineFallback() {
    Write-Host ""
    Write-Host '-----------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ' 兜底方案：请用此U盘重启电脑进入维修系统（场景②离线维修），' -ForegroundColor Yellow
    Write-Host ' 开机按启动菜单键(F12/F9/Esc)选择 U盘 启动，' -ForegroundColor Yellow
    Write-Host ' 无需在 Windows 内安装任何软件，也不依赖网络网关。' -ForegroundColor Yellow
    Write-Host '-----------------------------------------------------------' -ForegroundColor Yellow
}

# ---------------- 1. 权限状态检测（P-A A2：菜单先于提权，此处只检测不请求） ----------------
# 提权请求延迟到模式菜单选择「维修模式」时按需触发（-Verb RunAs 在主流程菜单分支内）；
# 拒绝提权不退出 —— 仅限制为只读诊断类任务（方案功能 1 定稿）。
$Script:IsAdmin = $false
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $Script:IsAdmin = $true
}

# ---------------- 2. 盘符定位（R5/R6：读自身所在路径定位U盘根与 /config/） ----------------
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Die '无法确定脚本所在目录。' '请将 repair-on-windows.ps1 放在U盘数据分区根目录后，通过 repair-on-windows.bat 启动。'
}
$Script:UsbRoot = $PSScriptRoot
$Script:ConfigDir = Join-Path $Script:UsbRoot 'config'
if (-not (Test-Path (Join-Path $Script:ConfigDir 'settings.conf'))) {
    Die "未在脚本所在目录找到 config\settings.conf（定位到: $Script:UsbRoot）。" '请确认本脚本位于 AI 维修U盘 数据分区根目录，未被复制到电脑本地运行。'
}
Write-Ok "U盘定位成功: $Script:UsbRoot"

# ---------------- 3. settings.conf 解析（R7/R8：方案 5.1 双兼容规则） ----------------
# 规则：KEY=VALUE，等号两侧无空格，值不加引号；# 仅允许整行注释。
# PS 解析：剥离整行注释后逐行按首个 = 切分（禁止行内注释语义，切分后值中的 # 视为普通字符丢弃不解析）。
function Read-SettingsConf([string]$Path) {
    $map = @{}
    $lineNo = 0
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $lineNo++
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }                 # 整行注释
        $idx = $line.IndexOf('=')
        if ($idx -le 0) {
            Write-Warn "settings.conf 第 $lineNo 行不符合 KEY=VALUE 格式（无等号），已忽略: $line"
            continue
        }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($key -ne $line.Substring(0, $idx)) {
            Write-Warn "settings.conf 第 $lineNo 行 KEY 两侧含空格（违反 5.1 规则），已尽力解析: $key"
        }
        $map[$key] = $val
    }
    return $map
}

$Script:Conf = Read-SettingsConf -Path (Join-Path $Script:ConfigDir 'settings.conf')
foreach ($required in @('ACTIVATE_URL', 'BALANCE_URL')) {
    if (-not $Script:Conf.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($Script:Conf[$required])) {
        Die "settings.conf 缺少必需配置项 $required（方案 5.1）。" '请用最新制作器重新制作U盘，或在 config\settings.conf 中补齐该行。'
    }
}
$Script:RecordMode = if ($Script:Conf.ContainsKey('RECORD_MODE')) { $Script:Conf['RECORD_MODE'] } else { 'customer' }
$Script:PromoDefault = if ($Script:Conf.ContainsKey('PROMO_CODE')) { $Script:Conf['PROMO_CODE'] } else { '' }
Write-Ok "配置解析成功（记录模式: $Script:RecordMode）"

# ---------------- 4. 指纹与序列号采集（R10/R11：功能 3，CIM 优先 / wmic 兜底） ----------------

# 机器指纹 = 主板序列号（比机器名稳：硬盘可能换）。wmic 在 Win11 24H2 起默认移除，仅兜底。
function Get-MachineFingerprint() {
    try {
        $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        if ($bb -and -not [string]::IsNullOrWhiteSpace($bb.SerialNumber)) {
            return $bb.SerialNumber.Trim()
        }
    } catch { Write-Warn "Get-CimInstance 取主板序列号失败: $($_.Exception.Message)" }
    try {
        $out = & wmic.exe baseboard get serialnumber /value 2>$null |
            Where-Object { $_ -match '^SerialNumber=(.+)$' } | Select-Object -First 1
        if ($out -match '^SerialNumber=(.+)$') { return $Matches[1].Trim() }
    } catch { Write-Warn "wmic 兜底取主板序列号失败: $($_.Exception.Message)" }
    Write-Warn '机器指纹采集失败（CIM 与 wmic 均不可用），本次以 UNKNOWN 参与（指纹仅作召回观察字段，不阻断）'
    return 'UNKNOWN'
}

# U盘序列号 = 脚本所在卷对应物理盘的 SerialNumber
function Get-UsbSerialNumber() {
    try {
        $driveLetter = $Script:UsbRoot.Substring(0, 1)
        $part = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($disk.SerialNumber)) {
            return $disk.SerialNumber.Trim()
        }
    } catch { Write-Warn "取U盘序列号失败: $($_.Exception.Message)" }
    return 'UNKNOWN'
}

# maker_version 归因字段（U盘根文件，缺省 unknown）
function Get-MakerVersion() {
    $p = Join-Path $Script:UsbRoot 'maker_version'
    if (Test-Path $p) {
        $v = (Get-Content $p -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return 'unknown'
}

# ---------------- 5. auth_token 读写（R9/R14：沿用 /config/auth_token 语义） ----------------

function Read-AuthToken() {
    $p = Join-Path $Script:ConfigDir 'auth_token'
    if (Test-Path $p) {
        $t = (Get-Content $p -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($t)) { return $t.Trim() }
    }
    return $null
}

function Write-AuthToken([string]$Key) {
    # 无 BOM UTF-8 + 末尾换行（bash 侧 welcome.sh 同读，行为一致）
    [System.IO.File]::WriteAllText((Join-Path $Script:ConfigDir 'auth_token'), ($Key + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# BATCH_ID 写入 settings.conf：有则更新该行，无则追加（幂等，不重复追加）
function Write-BatchId([string]$BatchId) {
    $p = Join-Path $Script:ConfigDir 'settings.conf'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([System.IO.File]::ReadAllLines($p))
    $written = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^BATCH_ID=') { $lines[$i] = "BATCH_ID=$BatchId"; $written = $true; break }
    }
    if (-not $written) { $lines.Add("BATCH_ID=$BatchId") }
    [System.IO.File]::WriteAllLines($p, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------- 6. 网关 API 封装（R13/R20/R26：重试 2 次 + 5.4 契约） ----------------

# 带重试的 POST/GET；网络层失败重试至 $NetMaxRetry 次；HTTP 错误状态以返回对象抛给调用方区分
function Invoke-GatewayApi([string]$Method, [string]$Url, [hashtable]$Body, [string]$AuthKey) {
    $lastErr = $null
    for ($i = 1; $i -le $Script:NetMaxRetry; $i++) {
        try {
            $params = @{
                Method      = $Method
                Uri         = $Url
                TimeoutSec  = $Script:HttpTimeoutSec
                ErrorAction = 'Stop'
            }
            if ($Body) { $params.Body = ($Body | ConvertTo-Json); $params.ContentType = 'application/json' }
            if ($AuthKey) { $params.Headers = @{ Authorization = "Bearer $AuthKey" } }   # 后端 /api/usb/* 校验 Bearer 前缀，裸 key 会 401
            return Invoke-RestMethod @params
        } catch {
            $lastErr = $_
            # HTTP 4xx/5xx 属业务分支（429/403/423/409 等），不重试直接上抛由调用方处理
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ge 400) { throw }
            Write-Warn "网关请求失败（第 $i/$Script:NetMaxRetry 次）: $Url"
            if ($i -lt $Script:NetMaxRetry) { Start-Sleep -Seconds (5 * $i) }
        }
    }
    throw "网关暂不可用（已重试 $($Script:NetMaxRetry) 次）: $($lastErr.Exception.Message)"
}

# 从 WebException 提取 HTTP 状态码
function Get-HttpStatusCode([System.Management.Automation.ErrorRecord]$Err) {
    if ($Err.Exception.Response) { return [int]$Err.Exception.Response.StatusCode }
    return 0
}

# ---------------- 7. 激活流程（R10-R21：方案 5.5，幂等五分支中文提示） ----------------

function Invoke-Activation() {
    Write-Step '首次使用：正在激活本U盘的免费维修额度 ...'
    $sn = Get-UsbSerialNumber
    $fp = Get-MachineFingerprint
    Write-Host "    U盘序列号: $sn"
    Write-Host "    机器指纹:   $fp"

    # 可选推广码（conf 有则作默认值，回车跳过）
    $promo = ''
    $prompt = if ([string]::IsNullOrWhiteSpace($Script:PromoDefault)) {
        '推广码（可留空直接回车跳过）'
    } else {
        "推广码（直接回车使用默认值 $($Script:PromoDefault)）"
    }
    $promoInput = Read-Host $prompt
    if (-not [string]::IsNullOrWhiteSpace($promoInput)) { $promo = $promoInput.Trim() }
    elseif (-not [string]::IsNullOrWhiteSpace($Script:PromoDefault)) { $promo = $Script:PromoDefault }

    $body = @{ usb_sn = $sn; machine_fp = $fp; maker_version = (Get-MakerVersion) }
    if (-not [string]::IsNullOrWhiteSpace($promo)) { $body.promo_code = $promo }

    try {
        # 200：新发 key 或同 SN 幂等返回原 key（并发竞态双方同 key 亦走此分支，R15/R21）
        $resp = Invoke-GatewayApi -Method Post -Url $Script:Conf['ACTIVATE_URL'] -Body $body
        if (-not $resp -or [string]::IsNullOrWhiteSpace($resp.key)) {
            Die '激活响应异常（缺少 key 字段）。' '请稍后重试；若持续失败请联系客服。'
        }
        Write-AuthToken -Key $resp.key
        if (-not [string]::IsNullOrWhiteSpace($resp.batch_id)) {
            Write-BatchId -BatchId $resp.batch_id
            Write-Ok "批次已记录: $($resp.batch_id)"
        }
        Write-Ok '激活成功，凭证已写回U盘（auth_token）'
        return $resp.key
    } catch {
        $code = Get-HttpStatusCode -Err $_
        switch ($code) {
            429 { Die '该网络今日激活次数已达上限（每 IP 每日限量）。' '请明日再试，或更换网络环境后重试。' }
            403 { Die 'U盘序列号校验失败（可能为伪造序列号）。' '请通过官网 https://tokeneff.com/usb 重新制作U盘后使用。' }
            423 { Die '该U盘已被风控暂停使用。' '请联系客服提供U盘序列号以核实处理。' }
            409 {
                # key 过期（12 个月）→ 走付费/续费通道（方案 5.4）
                Write-Fail '本U盘免费额度有效期已过（12 个月）。'
                Show-UpgradeHint
                Die '请走付费/续费通道后重试。' '免费 key 到期后不再重发，详见上方升级入口。'
            }
            default {
                # 网络失败重试 2 次后仍不可达 → 网关暂不可用，阻断并引导场景②（方案 5.3）
                Write-Fail "激活失败: $($_.Exception.Message)"
                Show-OfflineFallback
                Die '网关暂不可用，Windows 在线维修（场景③）完全依赖网关，本次无法继续。' '请按上方提示使用U盘离线维修（场景②），或稍后网络恢复再试。'
            }
        }
    }
}

# 升级入口提示（R19/R25：读U盘预置 URL 文件，方案 6.4 软着陆）
function Show-UpgradeHint() {
    $p = Join-Path $Script:UsbRoot $Script:UpgradeUrlFile
    if (Test-Path $p) {
        $url = (Get-Content $p -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($url)) {
            Write-Host "    升级 / 购买入口: $($url.Trim())" -ForegroundColor Yellow
            return
        }
    }
    Write-Host '    升级 / 购买入口: https://tokeneff.com （U盘未预置升级 URL 文件）' -ForegroundColor Yellow
}

# ---------------- 8. 余额查询与终端内邮箱验证（R22-R26：方案 5.4/5.5） ----------------

# 返回 $null 表示网关不可达（已重试 2 次）；返回 balance 对象为正常
function Get-Balance([string]$Key) {
    try {
        return Invoke-GatewayApi -Method Get -Url $Script:Conf['BALANCE_URL'] -Body $null -AuthKey $Key
    } catch {
        $code = Get-HttpStatusCode -Err $_
        if ($code -eq 401 -or $code -eq 403) {
            Die '凭证已失效（key 被吊销或校验失败）。' '请删除U盘 config\auth_token 后重新运行以重新激活，或联系客服。'
        }
        Write-Fail "余额查询失败: $($_.Exception.Message)"
        Show-OfflineFallback
        Die '网关暂不可用，Windows 在线维修（场景③）完全依赖网关，本次无法继续。' '请按上方提示使用U盘离线维修（场景②），或稍后网络恢复再试。'
    }
}

# 终端内邮箱验证：输邮箱 → POST /verify → 输码 → POST /verify/confirm（方案 5.4 定稿，不走网页跳转）
function Invoke-EmailVerification([string]$Key) {
    Write-Step '本U盘用量已触发邮箱验证（免费额度辅助风控）'
    Write-Host '    请输入您的邮箱收取验证码（验证一次后解除后续验证要求，限额不变）。'
    $email = (Read-Host '邮箱地址').Trim()
    if ([string]::IsNullOrWhiteSpace($email)) {
        Write-Warn '未输入邮箱，本次无法进入维修会话。'
        return $false
    }
    $verifyUrl = ($Script:Conf['BALANCE_URL'] -replace '/balance$') + '/verify'
    try {
        $vr = Invoke-GatewayApi -Method Post -Url $verifyUrl -Body @{ key = $Key; email = $email }
        if ($vr.already_verified) {
            Write-Ok '该凭证此前已通过邮箱验证，无需复核'
            return $true
        }
        Write-Ok '验证码已发送（有效期 10 分钟，请查收邮箱，注意垃圾箱）'
    } catch {
        $code = Get-HttpStatusCode -Err $_
        if ($code -eq 429) { Write-Warn '发送过于频繁（60 秒冷却 / 每日限 5 封），请稍后再试。' }
        else { Write-Warn "验证码发送失败: $($_.Exception.Message)" }
        return $false
    }
    $code = (Read-Host '请输入收到的 6 位验证码（直接回车放弃）').Trim()
    if ([string]::IsNullOrWhiteSpace($code)) { return $false }
    $confirmUrl = $verifyUrl + '/confirm'
    try {
        Invoke-GatewayApi -Method Post -Url $confirmUrl -Body @{ key = $Key; code = $code } | Out-Null
        Write-Ok '邮箱验证通过'
        return $true
    } catch {
        Write-Warn '验证码错误或已过期（单码最多尝试 5 次，超限作废需重发）。可重新查询余额再试。'
        return $false
    }
}

# ---------------- 9. CLAUDE_CONFIG_DIR 临时副本（R27/R28：功能 1 定稿，绝不覆写本地） ----------------

function Initialize-ClaudeConfigDir() {
    # 每次启动重建临时副本（旧残留先清），源缺失则建空目录不报错
    if (Test-Path $Script:TempClaudeDir) { Remove-Item $Script:TempClaudeDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $Script:TempClaudeDir | Out-Null
    $src = Join-Path $Script:ConfigDir 'claude-config'
    if (Test-Path $src) {
        Copy-Item -Path (Join-Path $src '*') -Destination $Script:TempClaudeDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "配置副本已就绪: $Script:TempClaudeDir"
    } else {
        Write-Warn "U盘缺少 config\claude-config\，已创建空临时配置目录"
    }
    # 注意：全程不触碰 %USERPROFILE%\.claude\（R28 零覆写红线）
    $env:CLAUDE_CONFIG_DIR = $Script:TempClaudeDir
}

# ---------------- 10. claude 检测与安装降级链（R29-R32：方案 5.3） ----------------

function Get-UsbClaudeExe() {
    # 便携模式（v0.2 决策）：制作器已把 Windows 原生版 claude.exe 放入 U盘 bin\，
    # 目标电脑无需在线安装直接运行；>100MB 为基本完整性判据（损坏/截断的 exe 走在线安装兜底）
    $p = Join-Path $Script:UsbRoot 'bin\claude.exe'
    if ((Test-Path $p) -and ((Get-Item $p).Length -gt 100MB)) { return $p }
    return $null
}

function Test-ClaudeAvailable() {
    if (Get-UsbClaudeExe) { return $true }
    return ($null -ne (Get-Command claude -ErrorAction SilentlyContinue))
}

function Install-Claude() {
    if (Get-UsbClaudeExe) {
        Write-Ok '检测到 U盘 内置 claude.exe（便携模式），无需安装'
        return $true
    }
    Write-Step '正在通过官方安装器安装 claude（首次使用需要，约 1-2 分钟）...'
    for ($i = 1; $i -le $Script:InstallMaxRetry; $i++) {
        try {
            $installText = Invoke-WebRequest -Uri $Script:ClaudeInstallUrl -UseBasicParsing -TimeoutSec $Script:HttpTimeoutSec -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($installText.Content) -or $installText.Content.Length -lt 100) {
                throw '安装器内容异常（为空或过短）'
            }
            # 以脚本块方式执行官方安装器（irm | iex 等价，可控超时与异常）
            $scriptBlock = [scriptblock]::Create($installText.Content)
            & $scriptBlock
            if (Test-ClaudeAvailable) {
                Write-Ok 'claude 安装成功'
                return $true
            }
            throw '安装器执行完毕但 claude 命令仍不可用（可能需重开终端刷新 PATH）'
        } catch {
            Write-Warn "安装失败（第 $i/$Script:InstallMaxRetry 次尝试）: $($_.Exception.Message)"
            if ($i -lt $Script:InstallMaxRetry) {
                Write-Host '    10 秒后重试...'
                Start-Sleep -Seconds 10
            }
        }
    }
    # 3 次均失败 → 常见原因中文诊断指引（方案 5.3 第 2 步）
    Write-Fail 'claude 在线安装多次失败，请依次排查以下常见原因：'
    Write-Host '  1) 安全软件拦截: 360/火绒/Defender 可能拦截 PowerShell 下载执行，请将 powershell.exe 加入白名单后重试' -ForegroundColor Yellow
    Write-Host '  2) 代理网络: 若电脑需代理上网，请先配置系统代理（或 $env:HTTPS_PROXY）后重试' -ForegroundColor Yellow
    Write-Host '  3) 磁盘空间: 请确认系统盘剩余空间大于 1GB' -ForegroundColor Yellow
    Write-Host '  4) 执行策略: 以管理员运行 powershell 执行 Set-ExecutionPolicy RemoteSigned 后重试' -ForegroundColor Yellow
    Show-OfflineFallback
    Die 'claude 安装失败，无法进行 Windows 在线维修。' '请按上方指引排查后重试，或直接用U盘离线维修（场景②），无需在 Windows 内安装任何软件。'
}

# ---------------- 10.5 agents.json 解析（P-A A2/A4：制作器勾选结果，驱动入口显隐） ----------------
# 存量盘无 agents.json → $null，全按现状兼容（Claude 在则用，菜单不出现 Codex 项）
$Script:Agents = $null
$agentsPath = Join-Path $Script:ConfigDir 'agents.json'
if (Test-Path $agentsPath) {
    try { $Script:Agents = Get-Content $agentsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Warn 'agents.json 解析失败，按无 Codex 处理' }
}
$Script:ClaudeDeclined = $false
$Script:CodexInstalled = $false
$Script:CodexDeclined  = $false
$Script:NodeInstalled  = $false
$Script:OpenclawInstalled = $false; $Script:OpenclawDeclined = $false
$Script:PiInstalled      = $false; $Script:PiDeclined = $false
if ($Script:Agents) {
    if ($Script:Agents.PSObject.Properties['claude'] -and $Script:Agents.claude.userDeclined -eq $true) {
        $Script:ClaudeDeclined = $true
    }
    if ($Script:Agents.PSObject.Properties['codex'] -and $Script:Agents.codex) {
        # installed=true → 可启动；userDeclined=true（未装）→ 灰色行提示；两者皆无 → 隐藏
        if ($Script:Agents.codex.installed -eq $true) { $Script:CodexInstalled = $true }
        elseif ($Script:Agents.codex.userDeclined -eq $true) { $Script:CodexDeclined = $true }
    }
    # P-B：OpenClaw / Pi / Node 同语义
    if ($Script:Agents.PSObject.Properties['node'] -and $Script:Agents.node -and $Script:Agents.node.installed -eq $true) {
        $Script:NodeInstalled = $true
    }
    if ($Script:Agents.PSObject.Properties['openclaw'] -and $Script:Agents.openclaw) {
        if ($Script:Agents.openclaw.installed -eq $true) { $Script:OpenclawInstalled = $true }
        elseif ($Script:Agents.openclaw.userDeclined -eq $true) { $Script:OpenclawDeclined = $true }
    }
    if ($Script:Agents.PSObject.Properties['pi'] -and $Script:Agents.pi) {
        if ($Script:Agents.pi.installed -eq $true) { $Script:PiInstalled = $true }
        elseif ($Script:Agents.pi.userDeclined -eq $true) { $Script:PiDeclined = $true }
    }
}

function Start-CodexSession() {
    # Codex CLI 会话（P-A A3）：便携 bin\codex.exe + CODEX_HOME 指向 config\codex
    $codexExe = Join-Path $Script:UsbRoot 'bin\codex.exe'
    if (-not (Test-Path $codexExe)) {
        Write-Warn 'bin\codex.exe 缺失（下载失败或已被删除）。重跑制作命令可补装。'
        Read-Host '按回车键返回' | Out-Null
        return
    }
    $codexHome = Join-Path $Script:ConfigDir 'codex'
    if (-not (Test-Path (Join-Path $codexHome 'config.toml'))) {
        Write-Warn "config\codex\config.toml 缺失，无法启动 Codex。重跑制作命令可补装。"
        Read-Host '按回车键返回' | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($Script:AuthKey)) {
        Write-Warn '未获取到凭证（auth_token），无法启动 Codex。请先经「查询余额 / 管理账号」完成激活。'
        Read-Host '按回车键返回' | Out-Null
        return
    }
    # 环境注入：key 仅进本进程环境，不落盘（功能 4 BYOK；同 Start-ClaudeSession 语义）
    $env:CODEX_HOME = $codexHome
    $env:TOKENEFF_API_KEY = $Script:AuthKey
    # PATH 前置 bin\ 与便携 Git（Codex 沙箱依赖 bash/git，与 claude 直跑共用 PortableGit）
    $binDir = Join-Path $Script:UsbRoot 'bin'
    $pg = Join-Path $binDir 'PortableGit'
    if (Test-Path (Join-Path $pg 'bin\bash.exe')) {
        $env:PATH = "$pg\cmd;$pg\bin;$pg\usr\bin;$binDir;$env:PATH"
    } else {
        $env:PATH = "$binDir;$env:PATH"
    }
    Write-Step '启动 Codex CLI 会话（退出会话后返回本菜单）'
    & $codexExe
    Write-Host ''
    Write-Ok '会话已结束，按回车返回'
    Read-Host | Out-Null
}

function Start-NodeAgentSession([string]$Name) {
    # P-B §3.3-3.5：OpenClaw / Pi 共用便携 Node 直启（不经 npm run——exFAT 无 .bin 符号链接）
    # $Name = 'openclaw' | 'pi'
    $nodeExe = Join-Path $Script:UsbRoot 'bin\node\node.exe'
    if (-not (Test-Path $nodeExe)) {
        Write-Warn 'bin\node\node.exe 缺失（Node 运行时未安装或已损坏）。重跑制作命令可补装。'
        Read-Host '按回车键返回' | Out-Null
        return
    }
    if ($Name -eq 'openclaw') {
        $entry = Join-Path $Script:UsbRoot 'bin\openclaw\node_modules\openclaw\openclaw.mjs'
        $title = 'OpenClaw 个人 AI 助理'
    } else {
        $entry = Join-Path $Script:UsbRoot 'bin\pi\node_modules\@mariozechner\pi-coding-agent\dist\cli.js'
        $title = 'Pi 编码 agent'
    }
    if (-not (Test-Path $entry)) {
        Write-Warn "入口缺失（$entry）。重跑制作命令可补装。"
        Read-Host '按回车键返回' | Out-Null
        return
    }
    # settings.conf 的 AUTH_TOKEN 允许缺失（老盘手工补的骨架无此键），回退读 auth_token 文件
    $token = $Script:Conf['AUTH_TOKEN']
    if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-AuthToken }
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Warn '未获取到凭证（auth_token），无法启动。请先经「查询余额 / 管理账号」完成激活。'
        Read-Host '按回车键返回' | Out-Null
        return
    }
    $binDir = Join-Path $Script:UsbRoot 'bin'
    # 环境注入：与 Claude 相同的两个网关变量（Anthropic 协议）；状态目录/npm 缓存重定向到 U盘（零残留 §3.3）
    $env:ANTHROPIC_BASE_URL = 'https://tokeneff.com'
    $env:ANTHROPIC_AUTH_TOKEN = $token   # 与 Claude 会话同源同款（仅 AUTH_TOKEN，避免个别 SDK 优先 API_KEY 走偏计费路径）
    $env:npm_config_cache = Join-Path $Script:ConfigDir 'npm-cache'
    $stateDir = Join-Path $Script:ConfigDir $Name
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    if ($Name -eq 'openclaw') { $env:OPENCLAW_STATE_DIR = $stateDir; $env:OPENCLAW_CONFIG_DIR = $stateDir }
    else { $env:PI_CONFIG_DIR = $stateDir; $env:PI_HOME = $stateDir }
    # PATH 前置 bin\node 与便携 Git（与 Claude/Codex 会话共用）
    $pg = Join-Path $binDir 'portablegit'
    if (Test-Path (Join-Path $pg 'bin\bash.exe')) {
        $env:PATH = "$pg\cmd;$pg\bin;$binDir\node;$binDir;$env:PATH"
    } else {
        $env:PATH = "$binDir\node;$binDir;$env:PATH"
    }
    Write-Step "启动 $title 会话（退出会话后返回本菜单）"
    & $nodeExe $entry
    Write-Host ''
    Write-Ok '会话已结束，按回车返回'
    Read-Host | Out-Null
}

# ---------------- 11. 会话启动（R29/R34/R35） ----------------

function Start-ClaudeSession([string]$Mode) {
    # 制作时明确未勾选 Claude 的盘：不触发在线安装回落，仅提示补装（P-A A2）
    if ($Script:ClaudeDeclined) {
        Write-Warn '此盘未安装 Claude 引擎（制作时未勾选）。重跑制作命令可补装。'
        Read-Host '按回车键返回' | Out-Null
        return
    }
    # 环境变量注入：key 仅进本进程环境，不落盘（功能 4 BYOK）
    $gateway = if ($Script:Conf.ContainsKey('GATEWAY_BASE_URL') -and -not [string]::IsNullOrWhiteSpace($Script:Conf['GATEWAY_BASE_URL'])) {
        $Script:Conf['GATEWAY_BASE_URL']
    } else { $Script:DefaultGatewayBase }
    $env:ANTHROPIC_BASE_URL = $gateway
    $env:ANTHROPIC_AUTH_TOKEN = $Script:AuthKey

    Initialize-ClaudeConfigDir

    if (-not (Test-ClaudeAvailable)) { Install-Claude }

    # 便携模式优先：直接运行 U盘 bin\claude.exe；exe 固化在盘上，禁用其自动更新
    $claudeCmd = Get-UsbClaudeExe
    if ($claudeCmd) {
        $env:DISABLE_AUTOUPDATER = '1'
        $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        # 便携 Git（U盘 bin\PortableGit）前置 PATH：Bash 工具依赖其 bash/git，目标电脑无需安装
        # PortableGit 布局：bin\bash.exe（bash 入口）、cmd\git.exe、usr\bin\coreutils
        $pg = Join-Path $Script:UsbRoot 'bin\PortableGit'
        if (Test-Path (Join-Path $pg 'bin\bash.exe')) {
            $env:PATH = "$pg\cmd;$pg\bin;$pg\usr\bin;$env:PATH"
        }
    } else {
        $claudeCmd = 'claude'
    }

    # 系统提示词：U盘根 CLAUDE.md 优先，其次 config\claude-config\CLAUDE.md
    $sysPrompt = $null
    foreach ($cand in @((Join-Path $Script:UsbRoot 'CLAUDE.md'), (Join-Path $Script:ConfigDir 'claude-config\CLAUDE.md'))) {
        if (Test-Path $cand) { $sysPrompt = $cand; break }
    }

    # 组装 claude 启动参数（splatting，避免空参数展开问题）
    $claudeArgs = @()
    if ($sysPrompt) { $claudeArgs += @('--system-prompt', (Get-Content $sysPrompt -Raw)) }
    if ($Mode -eq 'readonly') {
        Write-Step '启动只读诊断会话（本会话禁止任何写操作，仅收集信息与给出建议）'
        # 只读约束通过 --append-system-prompt 注入（不修改U盘上的 CLAUDE.md）
        $claudeArgs += @('--append-system-prompt', '【只读诊断模式】你处于只读诊断模式：禁止执行任何写操作（不改注册表、不删改文件、不停启用服务/驱动），只允许收集信息、诊断并给出文字建议。')
    } elseif ($Mode -eq 'office') {
        # 办公助手模式（P-A A2）：注入 config\office\CLAUDE.md 人格，无需提权
        Write-Step '启动办公助手会话（写文档/表格/文案，退出会话后返回本菜单）'
        $officeMd = Join-Path $Script:ConfigDir 'office\CLAUDE.md'
        if (Test-Path $officeMd) {
            # 人格同样经 --append-system-prompt 注入（已验证参数，不修改U盘上的 CLAUDE.md）
            $claudeArgs += @('--append-system-prompt', (Get-Content $officeMd -Raw))
        } else {
            Write-Warn "config\office\CLAUDE.md 缺失，将以通用模式启动（无人格注入）。"
        }
    } else {
        Write-Step '启动维修会话（退出会话后返回本菜单）'
    }
    & $claudeCmd @claudeArgs
    # 会话结束回落菜单
    Write-Host ''
    Write-Ok '会话已结束，按回车返回主菜单'
    Read-Host | Out-Null
}

# ---------------- 12. 退出清理（R36-R38：功能 4，脚本只清理临时副本本身） ----------------

function Invoke-ExitCleanup() {
    Write-Step '正在清理本机临时文件 ...'
    # 显式清除 key 环境变量示意（进程退出即消亡，双保险）
    $env:ANTHROPIC_AUTH_TOKEN = $null
    $env:ANTHROPIC_BASE_URL   = $null
    # 删除 %TEMP%\ai-repair\（含 claude 配置临时副本与临时 CLAUDE_CONFIG_DIR 下的会话历史，customer 语义）
    if (Test-Path $Script:TempRoot) {
        try {
            Remove-Item $Script:TempRoot -Recurse -Force -ErrorAction Stop
            Write-Ok '已删除本机临时目录（%TEMP%\ai-repair\）'
        } catch {
            Write-Warn "临时目录删除失败（可能有文件被占用，重启后系统会自动清理 TEMP）: $($_.Exception.Message)"
        }
    }
    # enterprise 模式：本地记录/会话历史保留由收尾任务文本驱动，脚本不硬编码删除（方案功能 4 定稿）
    if ($Script:RecordMode -eq 'enterprise') {
        Write-Host '    [企业运维模式] 会话历史与维修记录按企业模式保留（可审计可续修），' -ForegroundColor Cyan
        Write-Host '    收尾清理请按维修会话中的收尾任务指引执行。' -ForegroundColor Cyan
    } else {
        Write-Ok '上门服务模式：本机无维修痕迹残留（会话历史随临时目录一并清理）'
    }
    Write-Host ''
    Write-Host '===============================================' -ForegroundColor Green
    Write-Host '  感谢使用 AI 电脑维修U盘，再见！' -ForegroundColor Green
    Write-Host '===============================================' -ForegroundColor Green
    Read-Host '按回车键退出'
    exit 0
}

# ---------------- 0. 版本输出 ----------------
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  AI 电脑维修U盘 · Windows 在线维修（场景③）" -ForegroundColor Cyan
Write-Host "  启动器版本: $Script:ScriptVersion" -ForegroundColor Cyan
Write-Host "  官方发布页: https://tokeneff.com/usb" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan

# ---------------- 主流程 ----------------

# --- 激活闸门（R9-R21）：无 key → activate；有 key 直接进 ---
$Script:AuthKey = Read-AuthToken
if ([string]::IsNullOrWhiteSpace($Script:AuthKey)) {
    $Script:AuthKey = Invoke-Activation
} else {
    Write-Ok '已读取U盘凭证（auth_token）'
}

# --- 余额查询（R22）：每次启动必查 ---
Write-Step '正在查询剩余额度 ...'
$balance = Get-Balance -Key $Script:AuthKey
$remaining = $balance.remaining_weekly
Write-Ok "本周剩余额度: $remaining token（本月累计: $($balance.total_used_monthly)）"

# 低余额 / 用尽软着陆（R24/R25）
$lowBalance = $false
$exhausted  = $false
if ($remaining -is [int] -or $remaining -is [long] -or $remaining -is [double]) {
    if ($remaining -le 0) { $exhausted = $true }
    elseif ($remaining -lt 2000000) { $lowBalance = $true }   # <10% of 周 2000 万（宽松组基线）
}
if ($exhausted) {
    Write-Warn '本周免费额度已用完。'
    Show-UpgradeHint
    Write-Host '    升级套餐后即可继续使用，无任何隐性降速。' -ForegroundColor Yellow
} elseif ($lowBalance) {
    Write-Warn "本周额度已不足 10%（剩余 $remaining token），请合理安排使用或提前升级。"
    Show-UpgradeHint
}

# --- 邮箱验证（R23）：verification_required=true 时先行 ---
if ($balance.verification_required -eq $true) {
    $verified = Invoke-EmailVerification -Key $Script:AuthKey
    if (-not $verified) {
        Write-Warn '未完成邮箱验证：维修会话可能受限（超阈值未验证的 key 将被网关降档）。可稍后在菜单中重新触发。'
    }
}

# --- 模式菜单（P-A A2：菜单先于提权，选「维修模式」才触发 UAC） ---
# 激活/余额/邮箱验证对三种模式共用，已在上方完成；[2]/[3] 全程普通权限。
# -Elevated：提权重入（Start-Process -Verb RunAs 携带）直进维修模式，跳过模式菜单
$skipModeMenu = $Elevated.IsPresent
while ($true) {
    if ($skipModeMenu) { $choice = '1'; $skipModeMenu = $false }
    else {
        Write-Host ""
        Write-Host "---------------- 模式菜单 ----------------" -ForegroundColor Cyan
        Write-Host "  [1] 维修模式（需管理员权限，处理系统级问题）"
        Write-Host "  [2] 办公助手模式（无需提权，写文档/表格/文案）"
        Write-Host "  [3] 查询余额 / 管理账号"
        if ($Script:CodexInstalled) {
            Write-Host "  [4] Codex CLI（命令行 AI 助手，OpenAI 风格）"
        } elseif ($Script:CodexDeclined) {
            Write-Host "  [4] Codex CLI（未安装，重跑制作命令可补装）" -ForegroundColor DarkGray
        }
        if ($Script:OpenclawInstalled) {
            Write-Host "  [5] OpenClaw（个人 AI 助理）$(if (-not $Script:NodeInstalled) { '（Node 运行时缺失，重跑制作命令可补装）' })"
        } elseif ($Script:OpenclawDeclined) {
            Write-Host "  [5] OpenClaw（未安装，重跑制作命令可补装）" -ForegroundColor DarkGray
        }
        if ($Script:PiInstalled) {
            Write-Host "  [6] Pi（轻量编码 agent）$(if (-not $Script:NodeInstalled) { '（Node 运行时缺失，重跑制作命令可补装）' })"
        } elseif ($Script:PiDeclined) {
            Write-Host "  [6] Pi（未安装，重跑制作命令可补装）" -ForegroundColor DarkGray
        }
        Write-Host "  [0] 退出（清理本机临时文件）"
        $choice = (Read-Host '请输入编号').Trim()
    }
    switch ($choice) {
        '1' {
            # 维修模式：未提权时此处按需请求 UAC（拒绝 → 降级只读诊断，沿用 R3/R4 语义）
            if (-not $Script:IsAdmin) {
                if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
                    # 从管道执行（无文件路径）时无法自提升 → 只读诊断降级
                    Write-Warn '当前以管道方式运行，无法自动提权，本次仅允许只读诊断类任务。'
                } else {
                    Write-Warn '维修操作需要管理员权限，正在请求提权（请在弹出的 UAC 窗口点「是」）...'
                    try {
                        # 自提升并传 -Elevated 标记：新进程直进维修模式，防循环
                        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Normal -ArgumentList @(
                            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated'
                        )
                        exit 0    # 原低权进程退出，由提权后的新进程继续
                    } catch {
                        Write-Warn '用户取消了管理员授权 —— 本次仅允许只读诊断类任务。'
                    }
                }
            }
            # --- 维修模式子菜单（R33：原主菜单） ---
            while ($true) {
                Write-Host ""
                Write-Host "---------------- 维修模式 ----------------" -ForegroundColor Cyan
                if ($Script:IsAdmin) { Write-Host "  [1] 只读诊断（收集信息 + 给出建议，不改系统）"
                    Write-Host "  [2] 维修会话（需管理员权限，已具备）" }
                else { Write-Host "  [1] 只读诊断（收集信息 + 给出建议，不改系统）"
                    Write-Host "  [2] 维修会话（不可用：未获得管理员权限，请退回上级菜单重选「维修模式」并同意 UAC）" -ForegroundColor DarkGray }
                Write-Host "  [3] 余额查询"
                Write-Host "  [0] 返回上级菜单"
                $sub = (Read-Host '请输入编号').Trim()
                switch ($sub) {
                    '1' { Start-ClaudeSession -Mode 'readonly' }
                    '2' {
                        if (-not $Script:IsAdmin) {
                            Write-Warn '维修会话需要管理员权限。请输入 0 返回上级菜单，重选「维修模式」并在 UAC 弹窗中点「是」。'
                        } elseif ($exhausted) {
                            Write-Warn '本周免费额度已用完，无法进入维修会话。'
                            Show-UpgradeHint
                        } else {
                            Start-ClaudeSession -Mode 'repair'
                        }
                    }
                    '3' {
                        Write-Step '正在查询剩余额度 ...'
                        $b = Get-Balance -Key $Script:AuthKey
                        Write-Ok "本周剩余: $($b.remaining_weekly) token / 本月累计: $($b.total_used_monthly) / 有效期至: $($b.expires_at)"
                        if ($b.verification_required -eq $true) { Invoke-EmailVerification -Key $Script:AuthKey | Out-Null }
                    }
                    '0' { break }
                    default { Write-Warn '输入无效，请输入 0-3 的编号。' }
                }
            }
        }
        '2' {
            # 办公助手模式（P-A A2）：无需提权；用尽则拦截，低余额仅提醒
            if ($exhausted) {
                Write-Warn '本周免费额度已用完，无法进入办公助手会话。'
                Show-UpgradeHint
            } else {
                if ($lowBalance) { Write-Warn "本周额度已不足 10%（剩余 $remaining token），请合理安排使用。" }
                Start-ClaudeSession -Mode 'office'
            }
        }
        '3' {
            Write-Step '正在查询剩余额度 ...'
            $b = Get-Balance -Key $Script:AuthKey
            Write-Ok "本周剩余: $($b.remaining_weekly) token / 本月累计: $($b.total_used_monthly) / 有效期至: $($b.expires_at)"
            if ($b.verification_required -eq $true) { Invoke-EmailVerification -Key $Script:AuthKey | Out-Null }
        }
        '4' {
            if ($Script:CodexInstalled) { Start-CodexSession }
            elseif ($Script:CodexDeclined) { Write-Warn '此盘未安装 Codex CLI（制作时未勾选）。重跑制作命令可补装。' }
            else { Write-Warn '输入无效。' }
        }
        '5' {
            if ($Script:OpenclawInstalled) { Start-NodeAgentSession -Name 'openclaw' }
            elseif ($Script:OpenclawDeclined) { Write-Warn '此盘未安装 OpenClaw（制作时未勾选）。重跑制作命令可补装。' }
            else { Write-Warn '输入无效。' }
        }
        '6' {
            if ($Script:PiInstalled) { Start-NodeAgentSession -Name 'pi' }
            elseif ($Script:PiDeclined) { Write-Warn '此盘未安装 Pi（制作时未勾选）。重跑制作命令可补装。' }
            else { Write-Warn '输入无效。' }
        }
        '0' { Invoke-ExitCleanup }
        default { Write-Warn '输入无效，请输入 0-6 的编号。' }
    }
}
