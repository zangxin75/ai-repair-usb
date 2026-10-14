#!/usr/bin/env bash
# smoke.sh — Live 端脚本最小运行级冒烟测试（实施计划 R8a）
# 用途：在构建机上用 mock 夹具运行各脚本的可测逻辑，在真机验收前拦截运行级缺陷
# 用法：bash tests/smoke.sh   （在项目 05-执行工具/ 目录下执行）
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

echo
echo "=== 结果：通过 $PASS 项 / 失败 $FAIL 项 ==="
[[ $FAIL -eq 0 ]] || exit 1
