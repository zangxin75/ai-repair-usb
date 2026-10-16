#!/usr/bin/env bash
# smoke.sh — Live 端脚本最小运行级冒烟测试（实施计划 R8a）
# 用途：在构建机上用 mock 夹具运行各脚本的可测逻辑，在真机验收前拦截运行级缺陷
# 用法：bash tests/smoke.sh   （在项目 05-tools/ 目录下执行）
set -uo pipefail

cd "$(dirname "$0")/.."
BIN="build/live/usr/local/bin"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "=== 冒烟测试 1/4：--help 全量可运行 ==="
for f in "$BIN"/*.sh; do
  if bash "$f" --help >/dev/null 2>&1; then ok "$(basename "$f") --help"; else bad "$(basename "$f") --help 退出非零"; fi
done

echo "=== 冒烟测试 2/4：check-network.sh 五级逻辑（mock curl/ip/getent） ==="
MOCK=$(mktemp -d)
trap 'rm -rf "$MOCK"' EXIT
# mock：链路 UP、路由正常、DNS 正常、公网通、网关 401（视为通过）
cat > "$MOCK/ip" <<'EOF'
#!/bin/bash
if [[ "$1 $2" == "link show" ]]; then echo "2: eth0: <BROADCAST,UP> state UP"; exit 0; fi
if [[ "$1" == "route" ]]; then echo "default via 192.168.1.1 dev eth0"; exit 0; fi
EOF
cat > "$MOCK/getent" <<'EOF'
#!/bin/bash
echo "1.2.3.4 tokeneff.com"
EOF
cat > "$MOCK/curl" <<'EOF'
#!/bin/bash
# 区分第4级（公网）与第5级（网关API）：按 URL 返回不同码
for a in "$@"; do [[ "$a" == *tokeneff.com/v1/messages* ]] && { echo 401; exit 0; }; done
echo 200
EOF
chmod +x "$MOCK"/*
if PATH="$MOCK:$PATH" bash "$BIN/check-network.sh" --quiet; then
  ok "check-network 全通路径（mock 网关 401 → 通过）"
else
  bad "check-network 全通路径应退出 0"
fi
# mock 网关 500 → 应失败（退出码非零）
cat > "$MOCK/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do [[ "$a" == *tokeneff.com/v1/messages* ]] && { echo 500; exit 0; }; done
echo 200
EOF
if PATH="$MOCK:$PATH" bash "$BIN/check-network.sh" --quiet >/dev/null 2>&1; then
  bad "check-network 网关 500 应判失败却通过了"
else
  ok "check-network 网关 500 正确判失败"
fi

echo "=== 冒烟测试 3/4：mount-ventoy-data.sh 幂等分支（已挂载时直接退出 0） ==="
# mock mountpoint 返回已挂载；脚本自提权用真 sudo（mock sudo 会因 EUID 不变造成无限递归）
cat > "$MOCK/mountpoint" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$MOCK/mountpoint"
if sudo -n true 2>/dev/null; then
  if sudo -n env PATH="$MOCK:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
       bash "$BIN/mount-ventoy-data.sh" >/dev/null 2>&1; then
    ok "mount-ventoy-data 幂等分支（已挂载 → exit 0）"
  else
    bad "mount-ventoy-data 幂等分支应退出 0"
  fi
else
  echo "  - 本机 sudo 需密码，跳过该项（真机 Live 环境 live 用户免密 sudo，P2 验证）"
fi

echo "=== 冒烟测试 4/4：任务文本首行前缀一致性 ==="
PREFIX_OK=1
for t in build/live/usr/local/share/tasks/*.txt; do
  head -1 "$t" | grep -q "（系统流程，请直接开始执行，不要复述任务）" || { PREFIX_OK=0; bad "前缀缺失: $t"; }
done
[[ $PREFIX_OK -eq 1 ]] && ok "5 个任务文本首行前缀全部一致"

echo "=== 冒烟测试 5/8：技能 SKILL.md 结构（6 个） ==="
SKILLS="build/live/etc/skel/.claude/skills"
# 共享白名单：连续英文词检查的豁免 + 存在性校验的三类目标（防两处漂移，v1.1 计划 S3）
#   命令→包名映射（核对 package-lists）
CMD_PKG="smartctl:smartmontools ddrescue:gddrescue photorec:testdisk"
#   直名即包名（核对 package-lists）
CMD_DIRECT="testdisk rsync lshw sensors ntfs-3g"
#   脚本（核对 build/live/usr/local/bin）
CMD_SCRIPTS="disk-check.sh backup-user-data.sh install-windows.sh bitlocker-unlock.sh check-network.sh win-reset-password.sh"
#   基础系统隐式依赖，仅豁免英文词检查，不做存在性核对（grep package-lists 会误报）
CMD_EXEMPT="lsblk dmesg journalctl lspci badblocks ntfsfix efibootmgr wimlib"

# 检查 5-1：恰好 6 个技能目录、SKILL.md 存在、frontmatter 合法（name=目录名、description 非空 ≤60 字）
SKILL_NAMES="systematic-debugging verification-before-completion smart-diagnosis data-rescue reinstall-guardrail network-triage"
n=0
for d in "$SKILLS"/*/; do n=$((n+1)); done
[[ $n -eq 6 ]] && ok "技能目录恰好 6 个" || bad "技能目录数=$n（应为 6，防第 7 个混入）"
FM_OK=1
for s in $SKILL_NAMES; do
  f="$SKILLS/$s/SKILL.md"
  [[ -f "$f" ]] || { FM_OK=0; bad "缺失 $f"; continue; }
  name=$(awk '/^name:/{sub(/^name: */,"");print;exit}' "$f")
  [[ "$name" == "$s" ]] || { FM_OK=0; bad "$s: name=\"$name\" 与目录名不一致"; }
  desc=$(awk '/^description:/{sub(/^description: */,"");print;exit}' "$f")
  dlen=$(printf '%s' "$desc" | wc -m)
  [[ -n "$desc" && $dlen -le 60 ]] || { FM_OK=0; bad "$s: description 空或 ${dlen} 字（>60）"; }
done
[[ $FM_OK -eq 1 ]] && ok "6 个 SKILL.md 存在且 frontmatter 合法（name 一致、description ≤60 字）"

# 检查 5-2：正文 ≤120 行；连续 ≥4 个英文单词的行 = 0（白名单豁免）
LEN_OK=1; EN_OK=1
for s in $SKILL_NAMES; do
  f="$SKILLS/$s/SKILL.md"
  lines=$(wc -l < "$f")
  [[ $lines -le 120 ]] || { LEN_OK=0; bad "$s: 正文 $lines 行（>120）"; }
  # 提取白名单词逐一替换成占位符后再查连续 4 个英文词
  tmp=$(mktemp)
  cp "$f" "$tmp"
  for w in $CMD_PKG $CMD_DIRECT $CMD_SCRIPTS $CMD_EXEMPT; do
    c=${w%%:*}   # 映射条目取冒号前的命令名
    sed -i "s/\b${c//./\\.}\b/温/g" "$tmp"
  done
  if grep -nE '[A-Za-z]+ +[A-Za-z]+ +[A-Za-z]+ +[A-Za-z]+' "$tmp" >/dev/null; then
    EN_OK=0; bad "$s: 存在连续 ≥4 英文单词的行（疑似未本地化）: $(grep -nE '[A-Za-z]+ +[A-Za-z]+ +[A-Za-z]+ +[A-Za-z]+' "$tmp" | head -1)"
  fi
  rm -f "$tmp"
done
[[ $LEN_OK -eq 1 ]] && ok "6 个正文均 ≤120 行"
[[ $EN_OK -eq 1 ]] && ok "无连续 ≥4 英文单词的行（白名单豁免）"

# 检查 5-3：正文引用的命令/脚本存在（映射表三类目标）
PKG_LIST="live-build-config/config/package-lists"
REF_OK=1
for entry in $CMD_PKG; do
  c=${entry%%:*}; p=${entry##*:}
  grep -rqw -- "$c" "$SKILLS" || continue   # 正文未引用则不校验
  grep -rqw -- "$p" "$PKG_LIST"/*.list.chroot || { REF_OK=0; bad "命令 $c 已被引用但包 $p 不在 package-lists"; }
done
for c in $CMD_DIRECT; do
  grep -rqw -- "$c" "$SKILLS" || continue
  grep -rqw -- "$c" "$PKG_LIST"/*.list.chroot || { REF_OK=0; bad "命令 $c 已被引用但包不在 package-lists"; }
done
for sc in $CMD_SCRIPTS; do
  grep -rqw -- "$sc" "$SKILLS" || continue
  [[ -f "$BIN/$sc" ]] || { REF_OK=0; bad "脚本 $sc 已被引用但不在 $BIN"; }
done
[[ $REF_OK -eq 1 ]] && ok "正文引用的命令/脚本全部存在（映射表三类目标）"

# 检查 5-4：负例 description 禁词（防误触发）
NEG_OK=1
DR_DESC=$(awk '/^description:/{sub(/^description: */,"");print;exit}' "$SKILLS/data-rescue/SKILL.md")
RG_DESC=$(awk '/^description:/{sub(/^description: */,"");print;exit}' "$SKILLS/reinstall-guardrail/SKILL.md")
[[ "$DR_DESC" == *重装* ]] && { NEG_OK=0; bad "data-rescue description 含「重装」（会误触发数据抢救）"; }
[[ "$RG_DESC" == *坏道* || "$RG_DESC" == *异响* ]] && { NEG_OK=0; bad "reinstall-guardrail description 含「坏道/异响」"; }
[[ $NEG_OK -eq 1 ]] && ok "负例禁词零命中（重装×data-rescue、坏道异响×reinstall-guardrail）"

# ───────────────────────── 第 6 节：maker 产物断言（P-A A5，计划 §2） ─────────────────────────
MAKER="build/maker"

# 检查 6-1：容量两段预检——无硬编码 8GB 门槛；MinBaseGB=5 + 动态复查存在
S61=1
grep -q 'MinBaseGB' "$MAKER/usb-v1.0.ps1" || { S61=0; bad "usb-v1.0.ps1 缺 MinBaseGB 常量"; }
grep -Eq 'MinBaseGB[[:space:]]*=[[:space:]]*5' "$MAKER/usb-v1.0.ps1" || { S61=0; bad "usb-v1.0.ps1 MinBaseGB 应为 5"; }
grep -Eq 'MIN_BASE_GB=5' "$MAKER/usb-v1.0.sh" || { S61=0; bad "usb-v1.0.sh 缺 MIN_BASE_GB=5"; }
grep -n 'MinDiskGB\|MIN_DISK_GB' "$MAKER/usb-v1.0.ps1" "$MAKER/usb-v1.0.sh" | grep -qv '#' && { S61=0; bad "仍残留 MinDiskGB/MIN_DISK_GB 引用"; }
grep -q '容量动态复查' "$MAKER/usb-v1.0.ps1" || { S61=0; bad "usb-v1.0.ps1 缺容量动态复查段"; }
grep -q '容量动态复查' "$MAKER/usb-v1.0.sh" || { S61=0; bad "usb-v1.0.sh 缺容量动态复查段"; }
[[ $S61 -eq 1 ]] && ok "两段容量预检（选盘前 MinBaseGB=5 + 勾选后动态复查）"

# 检查 6-2：usb-v1.0.sh 支持 --agents
grep -q -- '--agents' "$MAKER/usb-v1.0.sh" && ok "usb-v1.0.sh 支持 --agents 参数" || bad "usb-v1.0.sh 缺 --agents 支持"

# 检查 6-3：两制作器均写 agents.json 与 isos.json
S63=1
for f in usb-v1.0.ps1 usb-v1.0.sh; do
  grep -q 'agents.json' "$MAKER/$f" || { S63=0; bad "$f 缺 agents.json 写入"; }
  grep -q 'isos.json' "$MAKER/$f" || { S63=0; bad "$f 缺 isos.json 写入"; }
done
[[ $S63 -eq 1 ]] && ok "两制作器均生成 agents.json / isos.json"

# 检查 6-4：提权重构——bat 无提权块；ps1 中 RunAs 仅在维修模式分支（锚文本序：模式菜单提示行号 < RunAs 行号）
S64=1
for b in repair-on-windows.bat AI-Workstation.bat; do
  grep -qe '-Verb RunAs' -e 'net session' "$MAKER/$b" && { S64=0; bad "$b 仍含提权块（-Verb RunAs / net session）"; }
  grep -q 'repair-on-windows.ps1' "$MAKER/$b" || { S64=0; bad "$b 未调用 repair-on-windows.ps1"; }
done
MENU_LINE=$(grep -n -- '模式菜单' "$MAKER/repair-on-windows.ps1" | head -1 | cut -d: -f1)
RUNAS_LINE=$(grep -n -- '-Verb RunAs' "$MAKER/repair-on-windows.ps1" | head -1 | cut -d: -f1)
[[ -n "$MENU_LINE" && -n "$RUNAS_LINE" && "$MENU_LINE" -lt "$RUNAS_LINE" ]] || { S64=0; bad "ps1 模式菜单锚文本行号($MENU_LINE) 应先于 RunAs($RUNAS_LINE)"; }
[[ $S64 -eq 1 ]] && ok "提权链重构（bat 无提权块；ps1 RunAs 仅在维修模式分支）"

# 检查 6-5：config.toml 模板内容（网关域名正确 + wire_api）
S65=1
for f in usb-v1.0.ps1 usb-v1.0.sh; do
  grep -q 'wire_api = "responses"' "$MAKER/$f" || { S65=0; bad "$f config.toml 模板缺 wire_api"; }
  grep -q 'base_url = "https://tokeneff.com/v1"' "$MAKER/$f" || { S65=0; bad "$f config.toml 模板 base_url 非法"; }
  grep -q 'api\.tokeneff\.com' "$MAKER/$f" && { S65=0; bad "$f 出现不存在的 api.tokeneff.com"; }
done
[[ $S65 -eq 1 ]] && ok "config.toml 模板（wire_api=responses / tokeneff.com/v1 / 无 api 子域）"

# 检查 6-6：AI-Workstation.bat 与 repair-on-windows.bat 逐字节一致且均调 ps1
if cmp -s "$MAKER/AI-Workstation.bat" "$MAKER/repair-on-windows.bat"; then
  ok "AI-Workstation.bat 与 repair-on-windows.bat 内容一致（cmp）"
else
  bad "AI-Workstation.bat 与 repair-on-windows.bat 内容不一致"
fi

# 检查 6-7：ventoy.json 生成段含「安装 Debian 12」别名分支（变量化条件）
S67=1
grep -q '安装 Debian 12' "$MAKER/usb-v1.0.ps1" || { S67=0; bad "usb-v1.0.ps1 ventoy 别名缺 Debian 分支"; }
grep -q '安装 Debian 12' "$MAKER/usb-v1.0.sh" || { S67=0; bad "usb-v1.0.sh ventoy 别名缺 Debian 分支"; }
[[ $S67 -eq 1 ]] && ok "ventoy.json 含「安装 Debian 12」条件别名分支"

# ───────────────────────── 第 7 节：P-B 产物断言（多Agent工作站 P-B：OpenClaw/Pi/Node） ─────────────────────────

# 检查 7-1：manifest 1.0.6 含 node/openclaw/pi 组件（url + sha256 非空，供应链钉值）
S71=1
for comp in node openclaw pi; do
  python3 - "$MAKER/manifest.json" "$comp" <<'PYCHK' || { S71=0; bad "manifest.json 组件 $comp 缺失或未钉 sha256"; }
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
for c in m['components']:
    if c['name'] == sys.argv[2] and c.get('url') and len(c.get('sha256','')) == 64:
        sys.exit(0)
sys.exit(1)
PYCHK
done
grep -q '"version": "1.0.6"' "$MAKER/manifest.json" || { S71=0; bad "manifest 版本应为 1.0.6"; }
[[ $S71 -eq 1 ]] && ok "manifest 1.0.6：node/openclaw/pi 组件已钉 url+sha256"

# 检查 7-2：两制作器含 OpenClaw/Pi 勾选 + Node 运行时处理 + 预装包下载段
S72=1
for f in usb-v1.0.ps1 usb-v1.0.sh; do
  grep -q 'OpenClaw' "$MAKER/$f" || { S72=0; bad "$f 缺 OpenClaw 勾选"; }
  grep -q 'pi-coding-agent' "$MAKER/$f" || { S72=0; bad "$f 缺 Pi 入口"; }
  grep -q 'bin\\node\\node.exe\|bin/node/node.exe' "$MAKER/$f" || { S72=0; bad "$f 缺 Node 运行时落盘"; }
done
grep -q -- '--agents claude,codex,openclaw,pi,node,linux' "$MAKER/usb-v1.0.sh" || { S72=0; bad "usb-v1.0.sh --agents 用法未列 openclaw/pi/node"; }
[[ $S72 -eq 1 ]] && ok "两制作器：OpenClaw/Pi 勾选 + Node 运行时 + --agents 扩展"

# 检查 7-3：启动器 0.4.3 含 OpenClaw/Pi 入口（agents.json 驱动显隐 + node 直启）
S73=1
grep -q "ScriptVersion   = '0.4.3'" "$MAKER/repair-on-windows.ps1" || { S73=0; bad "启动器版本应为 0.4.0"; }
grep -q 'Start-NodeAgentSession' "$MAKER/repair-on-windows.ps1" || { S73=0; bad "启动器缺 Start-NodeAgentSession"; }
grep -q 'openclaw.mjs' "$MAKER/repair-on-windows.ps1" || { S73=0; bad "启动器缺 OpenClaw 入口路径"; }
grep -q 'OPENCLAW_STATE_DIR' "$MAKER/repair-on-windows.ps1" || { S73=0; bad "启动器缺 OpenClaw 状态目录重定向"; }
grep -q 'npm_config_cache' "$MAKER/repair-on-windows.ps1" || { S73=0; bad "启动器缺 npm 缓存重定向（零残留）"; }
grep -q 'api\.tokeneff\.com' "$MAKER/repair-on-windows.ps1" "$MAKER/usb-v1.0.ps1" "$MAKER/usb-v1.0.sh" && { S73=0; bad "出现不存在的 api.tokeneff.com"; }
[[ $S73 -eq 1 ]] && ok "启动器 0.4.3：OpenClaw/Pi 入口 + Node 直启 + 零残留 env"

# 检查 7-4：制作器版本 1.3.8（四处全改：ps1 头注释+常量、sh 头注释+常量）
S74=1
grep -q "^# usb-v1.0.ps1 版本: 1.3.8" "$MAKER/usb-v1.0.ps1" || { S74=0; bad "ps1 头注释版本未升 1.3.8"; }
grep -q "ScriptVersion   = '1.3.8'" "$MAKER/usb-v1.0.ps1" || { S74=0; bad "ps1 常量版本未升 1.3.8"; }
grep -q "^# usb-v1.0.sh 版本: 1.3.8" "$MAKER/usb-v1.0.sh" || { S74=0; bad "sh 头注释版本未升 1.3.8"; }
grep -q 'SCRIPT_VERSION="1.3.8"' "$MAKER/usb-v1.0.sh" || { S74=0; bad "sh 常量版本未升 1.3.8"; }
# 1.3.5 遗留：codex 拷后改名 codex.exe（robocopy 保留源文件名，不改名最终校验 bin\codex.exe 必炸）
grep -q "Copy-FileWithProgress \$codexSrc (Join-Path \$Script:UsbRoot 'bin') 'codex.exe'" "$MAKER/usb-v1.0.ps1" \
  || { S74=0; bad "ps1 codex 落盘未改名 codex.exe"; }
# 三振/降级语义锚：降级分支（确定性失败）保留 Write-Warn + installedFinal = $false，不得被三振 Die 吞掉
grep -q 'Write-Warn "OpenClaw 落盘失败' "$MAKER/usb-v1.0.ps1" || { S74=0; bad "ps1 OpenClaw 降级分支（Write-Warn）缺失"; }
grep -q 'openclawInstalledFinal = \$false' "$MAKER/usb-v1.0.ps1" || { S74=0; bad "ps1 installedFinal = \$false 降级语义缺失"; }
[[ $S74 -eq 1 ]] && ok "两制作器版本 1.3.8（四处）+ codex 改名 + 降级语义锚"

# 检查 7-5：解压进度心跳 + exFAT 容错（1.3.2）
S75=1
grep -q 'Expand-WithProgress' "$MAKER/usb-v1.0.ps1" || { S75=0; bad "usb-v1.0.ps1 缺 Expand-WithProgress"; }
grep -q 'Write-Progress' "$MAKER/usb-v1.0.ps1" || { S75=0; bad "usb-v1.0.ps1 缺 Write-Progress"; }
grep -q 'extract_progress' "$MAKER/usb-v1.0.sh" || { S75=0; bad "usb-v1.0.sh 缺 extract_progress"; }
[ "$(grep -c 'Expand-Archive -Path' "$MAKER/usb-v1.0.ps1")" -le 1 ] || { S75=0; bad "ps1 仍有无进度 Expand-Archive 直调残留（仅允许 helper 回退分支 1 处）"; }
# 1.3.4：脚本头全局 SilentlyContinue 会压制 Write-Progress → helper 内必须临时恢复并还原
grep -q "\$ProgressPreference = 'Continue'" "$MAKER/usb-v1.0.ps1" || { S75=0; bad "ps1 Expand-WithProgress 未恢复 ProgressPreference（进度条被全局静默压制）"; }
grep -q '\$ProgressPreference = \$prevProgress' "$MAKER/usb-v1.0.ps1" || { S75=0; bad "ps1 Expand-WithProgress 未还原 ProgressPreference（会拖慢后续 BITS 下载）"; }
[[ $S75 -eq 1 ]] && ok "两制作器：解压进度心跳 + 容错（tar.exe/Write-Progress、du 轮询、入口判定）"

# 检查 7-6：掉盘鲁棒性 1.3.8（缓存保留 / 两段式 / 恢复 / 对账 / 原子写 / 文案）
S76=1
# 拷贝旗标：ps1 无 /Z 无 /MT:（多线程在 flaky USB 上放大失败面）
grep -q '/MT:' "$MAKER/usb-v1.0.ps1" && { S76=0; bad "ps1 仍有 robocopy /MT:"; }
grep -q 'robocopy.*/Z[^a-zA-Z]' "$MAKER/usb-v1.0.ps1" && { S76=0; bad "ps1 出现 robocopy /Z"; }
# ps1 掉盘判定：robocopy 退出码 ≥8 + Test-Path 盘符检测 + 恢复函数 + 三振 Die
grep -q '\-ge 8' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 缺 robocopy ≥8 失败判定"; }
grep -q 'function Wait-UsbReturn' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 缺 Wait-UsbReturn 恢复函数"; }
grep -q 'function Invoke-UsbCopy' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 缺 Invoke-UsbCopy 三振包装器"; }
grep -q '连续失败 3 次\|连续失败 \${fail} 次' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 三振 Die 文案缺失"; }
# 拷贝段进度：Copy-TreeWithRecovery 内 Write-Progress 轮询 + 完成只认退出码
grep -q 'function Copy-TreeWithRecovery' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 缺 Copy-TreeWithRecovery"; }
awk '/function Copy-TreeWithRecovery/,/^}/' "$MAKER/usb-v1.0.ps1" | grep -q 'Write-Progress' \
  || { S76=0; bad "Copy-TreeWithRecovery 缺 Write-Progress 轮询（10k 文件拷贝会被当假死）"; }
# 对账 + 原子写
grep -q 'function Assert-TreeSynced' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 缺 Assert-TreeSynced 三对账"; }
grep -q "agents.json.tmp" "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 agents.json 未原子写"; }
# nonce：写盘动作在 Ventoy 段之后（行号序；常量定义行不算）
NP1=$(grep -n 'Write-Ok .Ventoy 引导层写入完成' "$MAKER/usb-v1.0.ps1" | head -1 | cut -d: -f1)
NP2=$(grep -n 'WriteAllText((Join-Path $Script:UsbRoot $Script:NonceFile)' "$MAKER/usb-v1.0.ps1" | head -1 | cut -d: -f1)
[ -n "$NP1" ] && [ -n "$NP2" ] && [ "$NP2" -gt "$NP1" ] || { S76=0; bad "ps1 nonce 写入时机不在 Ventoy 段之后"; }
# ps1 收尾文案（此步最慢请勿拔盘 / 杀软扫描等待）
grep -q '请勿拔盘' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 缺「请勿拔盘」文案"; }
grep -q '杀毒软件扫描' "$MAKER/usb-v1.0.ps1" || { S76=0; bad "ps1 缺杀软扫描等待文案"; }

# sh 侧：CACHE 固定路径 + trap 不清缓存 + 全部下载段 dest 含 $CACHE + mountpoint 判定 + rsync 旗标 + 原子写
grep -q 'CACHE="${HOME}/.cache/ai-repair-usb-maker"' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh CACHE 未固定到 ~/.cache"; }
grep "trap .*EXIT" "$MAKER/usb-v1.0.sh" | grep -q '\$CACHE' && { S76=0; bad "sh trap 泄漏引用 \$CACHE（缓存会被误删）"; }
# 下载段 dest 均指 $CACHE：§6 主循环 + 6.5/6.6/6.7/6.8 的 fetch_retry/cache_hit 目标
for pat in 'dest="${CACHE}/${fname}"' 'portable-bin/TempClaude.exe' 'portable-bin/TempPortableGit.zip' \
           '"${CACHE}/codex-download.exe"' '"${CACHE}/${DEBIAN_NAME}"' '"${CACHE}/${NODE_FNAME}"' \
           '"${CACHE}/${OC_FNAME}"' '"${CACHE}/${PI_FNAME}"'; do
  grep -q -- "$pat" "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh 下载段 dest 未指向缓存: $pat"; }
done
grep -q 'cache_hit ' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh 缺 cache_hit 缓存命中检查"; }
# 掉盘判定：mountpoint（而非 [ -d "$MNT" ]）+ umount -l 兜底 + nonce 重定位 + 三振
grep -q 'mountpoint -q "$MNT"' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh 缺 mountpoint 挂载态检测"; }
grep -q '\[ -d "\$MNT" \]' "$MAKER/usb-v1.0.sh" && { S76=0; bad "sh 仍有 [ -d \"\$MNT\" ] 掉盘判定（恒真，检测不到掉盘）"; }
grep -q 'umount -l "$MNT"' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh 缺 umount -l lazy 兜底"; }
grep -q '连续失败' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh 三振 Die 文案缺失"; }
# rsync 旗标串（含 -rt --partial --inplace，无 --no-times）
grep -q -- '-rt --partial --inplace --no-perms --no-owner' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh rsync 旗标串缺失"; }
grep -q -- '--no-times' "$MAKER/usb-v1.0.sh" && { S76=0; bad "sh rsync 带 --no-times（对账用 mtime，禁止）"; }
# sh 三对账 + 原子写 + nonce
grep -q 'assert_tree_synced' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh 缺三对账函数"; }
grep -q 'agents.json.tmp' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh agents.json 未原子写"; }
grep -q '\.ai-repair-maker-session' "$MAKER/usb-v1.0.sh" || { S76=0; bad "sh 缺 nonce 标识文件"; }
[[ $S76 -eq 1 ]] && ok "1.3.7 掉盘鲁棒性：缓存保留+两段式+恢复+对账+原子写（双侧）"

echo
echo "=== 结果：通过 $PASS 项 / 失败 $FAIL 项 ==="
[[ $FAIL -eq 0 ]] || exit 1
