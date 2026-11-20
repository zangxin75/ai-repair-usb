#!/usr/bin/env bash
# repair-on-linux-smoke.sh — 场景③ Linux 启动器 mock 冒烟测试
# =====================================================================
# 创建日期: 2026-11-20 / 版本 1.0 / 状态: 随 v0.1.0 首发 / 作者: Claude Code + kt
# 设计依据: 04-design/技术方案_AI电脑维修U盘_场景三Linux在线维修启动器_20261120.md §9
# 用法: 在 05-tools/ 下运行  bash tests/repair-on-linux-smoke.sh
# 原理: PATH shim mock curl/sudo/sleep/claude（不碰真机、不碰真实网关），
#       每场景搭独立假U盘目录（启动器副本 + config/）。
# =====================================================================
set -u
cd "$(dirname "$0")/.." || exit 1

LAUNCHER="$PWD/build/maker/repair-on-linux.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
assert_in() { # $1=haystack $2=needle $3=用例名
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3（未命中: $2）"; fi
}
assert_ni() { # not-in
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3（不应命中: $2）"; else ok "$3"; fi
}

# ---------------- mock 环境 ----------------
MOCK="$(mktemp -d)"; chmod 700 "$MOCK"
cat > "$MOCK/curl" <<'EOF'
#!/bin/bash
[ -n "${MOCK_CURL_FAIL:-}" ] && exit 7
out=""; want_code=0; prev=""; url="${@: -1}"
for a in "$@"; do
    case "$prev" in
        -o) out="$a" ;;
        -w) [ "$a" = '%{http_code}' ] && want_code=1 ;;
    esac
    prev="$a"
done
body='{"detail":"mock-404"}'; code="404"
case "$url" in
    */api/usb/activate)      code="${MOCK_ACTIVATE_CODE:-200}"; body="${MOCK_ACTIVATE_BODY:-\{\}}" ;;
    */api/usb/balance)       code="${MOCK_BALANCE_CODE:-200}";  body="${MOCK_BALANCE_BODY:-\{\}}" ;;
    */api/usb/verify/confirm) code="${MOCK_CONFIRM_CODE:-200}"; body="${MOCK_CONFIRM_BODY:-\{\}}" ;;
    */api/usb/verify)        code="${MOCK_VERIFY_CODE:-200}";   body="${MOCK_VERIFY_BODY:-\{\}}" ;;
    */stable)                body="9.9.9" ;;
    */manifest.json)         body="${MOCK_GCS_MANIFEST:-\{\}}" ;;
    */linux-x64/claude)
        if [ -n "$out" ] && [ "$out" != "-" ]; then printf '%s' "${MOCK_GCS_ENGINE:-}" > "$out"
        else printf '%s' "${MOCK_GCS_ENGINE:-}"; fi
        [ "$want_code" = 1 ] && printf '200'
        exit 0 ;;
esac
if [ -n "$out" ] && [ "$out" != "-" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
[ "$want_code" = 1 ] && printf '%s' "$code"
exit 0
EOF
printf '#!/bin/bash\nexit "${MOCK_SUDO_RC:-1}"\n'      > "$MOCK/sudo"
printf '#!/bin/bash\nexit 0\n'                        > "$MOCK/sleep"
printf '#!/bin/bash\necho SYSTEM_ENGINE_RAN\nexit 0\n' > "$MOCK/claude"
chmod +x "$MOCK"/*
# 交互读取回落 stdin（ask() 默认会绑 /dev/tty，会让管道喂答案失效）；
# 审计扫描根隔离到空目录（真机恰好挂着本项目U盘时测试仍可复现）
export AI_REPAIR_ASK_STDIN=1
AUDIT_NONE="$(mktemp -d)"
export AI_REPAIR_AUDIT_ROOTS="$AUDIT_NONE"

# 假U盘搭建：mk_usb [RECORD_MODE] → 假U盘根目录；启动器副本 + settings.conf
mk_usb() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/fakeusb.XXXXXX")"
    cp "$LAUNCHER" "$d/repair-on-linux.sh"
    mkdir -p "$d/config"
    cat > "$d/config/settings.conf" <<EOF
RECORD_MODE=${1:-customer}
GATEWAY_BASE_URL=https://tokeneff.com
ACTIVATE_URL=https://gw.test/api/usb/activate
BALANCE_URL=https://gw.test/api/usb/balance
PROMO_CODE=
CONFIG_OVERRIDE=1
EOF
    printf '%s\n' "$d"
}
# 便携引擎（假 ELF：可执行 shell 小脚本）+ 正确 .sha256 旁车
put_engine() { # $1=usb根
    mkdir -p "$1/bin"
    cat > "$1/bin/claude-linux" <<'EOF'
#!/bin/sh
echo "ENGINE_ARGS: $*"
echo "ENGINE_BASE_URL: $ANTHROPIC_BASE_URL"
echo "ENGINE_TOKEN: ${ANTHROPIC_AUTH_TOKEN:+set}"
echo "ENGINE_APIKEY: ${ANTHROPIC_API_KEY:+SET-BAD}"
echo "ENGINE_MODEL: $ANTHROPIC_MODEL"
exit 0
EOF
    chmod +x "$1/bin/claude-linux"
    sha256sum "$1/bin/claude-linux" | awk '{print $1}' > "$1/bin/claude-linux.sha256"
}
run_l() { # $1=usb根 $2=stdin（\n 转义）
    printf '%b' "$2" | PATH="$MOCK:$PATH" bash "$1/repair-on-linux.sh" 2>&1
}
BAL_OK='{"remaining_weekly":10000000,"total_used_monthly":5000000,"expires_at":"2027-11-20"}'
BAL_LOW='{"remaining_weekly":1500000,"total_used_monthly":5000000,"expires_at":"2027-11-20"}'
BAL_ZERO='{"remaining_weekly":0,"total_used_monthly":20000000,"expires_at":"2027-11-20"}'
PRE_RESIDUE="$(ls -d "${TMPDIR:-/tmp}"/ai-repair.* 2>/dev/null | sort)"

echo '== 1. 静态检查 =='
bash -n "$LAUNCHER" && ok 'bash -n 启动器' || bad 'bash -n 启动器'
bash -n build/maker/usb-v1.0.sh && ok 'bash -n 制作器' || bad 'bash -n 制作器'
h="$(PATH="$MOCK:$PATH" bash "$LAUNCHER" --help 2>&1)"; rc=$?
[ $rc -eq 0 ] && assert_in "$h" '用法' '--help 退出码 0 + 用法' || bad '--help 退出码非 0'

echo '== 2. 前置拒绝 + 环境自审 =='
BARE="$(mktemp -d)"; cp "$LAUNCHER" "$BARE/repair-on-linux.sh"
out="$(run_l "$BARE" '\n\n')"; rc=$?
[ $rc -ne 0 ] && assert_in "$out" '启动器不在本项目的U盘上运行' 'S2a 裸跑拦截（curl 单跑场景）' || bad 'S2a 裸跑应退出非 0'
assert_in "$out" 'usb-v1.0.sh | sudo bash' 'S2b 裸跑指路制作命令'
USB2="$(mk_usb)"
AI_REPAIR_AUDIT_ROOTS="$USB2" out="$(run_l "$BARE" '\n\n')"; rc=$?
[ $rc -ne 0 ] && assert_in "$out" "bash \"$USB2/repair-on-linux.sh\"" 'S2c 已插U盘时给出确切启动命令' || bad 'S2c 已插U盘应退出非 0 并指路'
BARE2="$(mktemp -d)"; cp "$LAUNCHER" "$BARE2/repair-on-linux.sh"; touch "$BARE2/repair-on-windows.ps1"
out="$(run_l "$BARE2" '\n\n')"; rc=$?
[ $rc -ne 0 ] && assert_in "$out" '未在脚本所在目录找到' 'S2d 审计放行后无 settings.conf 兜底拒跑' || bad 'S2d 兜底应退出非 0'
U="$(mk_usb)"; grep -v '^ACTIVATE_URL=' "$U/config/settings.conf" > "$U/config/settings.conf.tmp" && mv "$U/config/settings.conf.tmp" "$U/config/settings.conf"
out="$(run_l "$U" '\n\n')"
assert_in "$out" '缺少必需配置项 ACTIVATE_URL' 'S3 settings.conf 缺必需项拒绝'
out="$(PATH="$MOCK:$PATH" bash "$LAUNCHER" --repair 2>&1)"; rc=$?
[ $rc -ne 0 ] && assert_in "$out" '--repair 参数需要 root' 'S4 --repair 非 root 拒绝' || bad 'S4 --repair 非 root 应拒绝'

echo '== 3. 激活 5 分支 + 网络耗尽 =='
export MOCK_BALANCE_CODE=200 MOCK_BALANCE_BODY="$BAL_OK"
U="$(mk_usb)"
export MOCK_ACTIVATE_CODE=200 MOCK_ACTIVATE_BODY='{"key":"k-abc123","batch_id":"B-20261120-01"}'
out="$(run_l "$U" '\n0\n\n')"
assert_in "$out" '激活成功' 'S5a 激活 200 成功文案'
[ "$(tr -d '[:space:]' < "$U/config/auth_token")" = "k-abc123" ] && ok 'S5b auth_token 落盘' || bad 'S5b auth_token 落盘'
grep -q '^BATCH_ID=B-20261120-01$' "$U/config/settings.conf" && ok 'S5c BATCH_ID 幂等写回' || bad 'S5c BATCH_ID 幂等写回'
export MOCK_ACTIVATE_BODY='{"detail":"sn-blacklisted"}'
for branch in '429|每 IP 每日限量' '403|sn-blacklisted' '423|风控暂停' '409|有效期已过'; do
    code="${branch%%|*}"; needle="${branch#*|}"
    export MOCK_ACTIVATE_CODE="$code" MOCK_ACTIVATE_BODY='{"detail":"x"}'
    [ "$code" = 403 ] && export MOCK_ACTIVATE_BODY='{"detail":"sn-blacklisted"}'
    U="$(mk_usb)"; out="$(run_l "$U" '\n\n')"
    assert_in "$out" "$needle" "S6 激活 $code 分支文案"
done
U="$(mk_usb)"
export MOCK_CURL_FAIL=1; out="$(run_l "$U" '\n\n')"; unset MOCK_CURL_FAIL
assert_in "$out" '网关暂不可用' 'S10a 网络耗尽 die'
assert_in "$out" '场景②离线维修' 'S10b 离线兜底提示'

echo '== 4. 余额分支与闸门 =='
export MOCK_ACTIVATE_CODE=200 MOCK_ACTIVATE_BODY='{"key":"k-x"}'
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"
export MOCK_BALANCE_CODE=401
out="$(run_l "$U" '\n')"
assert_in "$out" '凭证已失效' 'S11 余额 401 吊销文案'
export MOCK_BALANCE_CODE=200 MOCK_BALANCE_BODY="$BAL_ZERO"
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"; put_engine "$U"
out="$(run_l "$U" '2\n\n3\n\n4\n\n0\n\n')"
assert_in "$out" '本周免费额度已用完' 'S12a 耗尽提示'
assert_in "$out" '无法进入维修会话' 'S12b [2] 被闸'
assert_in "$out" '无法进入该会话' 'S12c [3]/[4] 被闸'
assert_ni "$out" 'ENGINE_ARGS' 'S12d 耗尽时无会话启动'

echo '== 5. 会话模式与引擎链 =='
export MOCK_BALANCE_BODY="$BAL_LOW"
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"; put_engine "$U"
out="$(run_l "$U" '1\n\n0\n\n')"
assert_in "$out" '不足 10%' 'S13a 低余额预警'
assert_in "$out" '只读诊断模式' 'S13b readonly 注入 append-system-prompt'
assert_in "$out" 'ENGINE_BASE_URL: https://tokeneff.com' 'S13c BASE_URL 注入'
assert_in "$out" 'ENGINE_TOKEN: set' 'S13d AUTH_TOKEN 注入'
assert_ni "$out" 'SET-BAD' 'S13e 残留 API_KEY 已清'
assert_in "$out" 'ENGINE_MODEL: claude-sonnet-5' 'S13f 模型钉扎'
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"; put_engine "$U"
out="$(run_l "$U" '4\n\n0\n\n')"
assert_in "$out" '--dangerously-skip-permissions' 'S14 code 模式完全控制'
export MOCK_SUDO_RC=1
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"; put_engine "$U"
out="$(run_l "$U" '2\n\n0\n\n')"
assert_in "$out" '未获得管理员授权' 'S15a sudo 拒绝降级文案'
assert_in "$out" '只读诊断模式' 'S15b 降级 readonly 会话生效'
export MOCK_SUDO_RC=0
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"; put_engine "$U"
out="$(run_l "$U" '2\n\n')"
assert_in "$out" '维修会话已结束' 'S16 sudo 成功后整体退出'
export MOCK_SUDO_RC=1
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"; put_engine "$U"
printf 'deadbeef\n' > "$U/bin/claude-linux.sha256"
out="$(run_l "$U" '1\n\n0\n\n')"
assert_in "$out" '旁车校验失败' 'S17a 旁车不匹配拒便携引擎'
assert_in "$out" '本机已装 claude' 'S17b 回落本机 claude'
assert_in "$out" 'SYSTEM_ENGINE_RAN' 'S17c 本机引擎会话运行'

echo '== 6. 邮箱验证两步 =='
export MOCK_BALANCE_BODY='{"remaining_weekly":10000000,"total_used_monthly":0,"expires_at":"2027-11-20","verification_required":true}'
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"
export MOCK_VERIFY_CODE=200 MOCK_VERIFY_BODY='{"already_verified":true}'
out="$(run_l "$U" 'a@b.c\n0\n\n')"
assert_in "$out" '该凭证此前已通过邮箱验证' 'S19 already_verified 免复核'
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"
export MOCK_VERIFY_BODY='{"sent":true}' MOCK_CONFIRM_CODE=200 MOCK_CONFIRM_BODY='{"ok":true}'
out="$(run_l "$U" 'a@b.c\n123456\n0\n\n')"
assert_in "$out" '验证码已发送' 'S20a 验证码发送文案'
assert_in "$out" '邮箱验证通过' 'S20b 两步确认通过'
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"
export MOCK_VERIFY_CODE=429 MOCK_VERIFY_BODY='{"detail":"cooling"}'
out="$(run_l "$U" 'a@b.c\n0\n\n')"
assert_in "$out" '发送过于频繁' 'S22 verify 429 冷却文案'

echo '== 7. sed 第三层 + 在线引擎（受限 PATH：无 jq/python3/claude） =='
MOCK2="$(mktemp -d)"
for c in id mktemp chmod cp rm mkdir tr sed grep awk stat sha256sum readlink dirname findmnt df cat head tail seq uname; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$MOCK2/$c"
done
cp "$MOCK/curl" "$MOCK/sleep" "$MOCK2/"
chmod +x "$MOCK2/curl" "$MOCK2/sleep"
export MOCK_BALANCE_BODY="$BAL_LOW"
export MOCK_ACTIVATE_CODE=200 MOCK_ACTIVATE_BODY='{"key":"k-sed","batch_id":"B-2"}'
GCS_ENGINE='#!/bin/sh
echo "ENGINE_ARGS: $*"
exit 0'
GCS_SHA="$(printf '%s' "$GCS_ENGINE" | sha256sum | awk '{print $1}')"
export MOCK_GCS_ENGINE="$GCS_ENGINE"
export MOCK_GCS_MANIFEST="$(printf '{\n  "linux-x64": {\n    "binary": "claude",\n    "checksum": "%s",\n    "size": 294\n  },\n  "win32-x64": {\n    "checksum": "ffff"\n  }\n}' "$GCS_SHA")"
U="$(mk_usb)"
out="$(printf '%b' '\n1\n\n0\n\n' | PATH="$MOCK2" /bin/bash "$U/repair-on-linux.sh" 2>&1)"
assert_in "$out" '激活成功' 'S18a sed 层激活解析'
assert_in "$out" '本周剩余额度: 1500000' 'S18b sed 层数字余额解析'
assert_in "$out" '在线引擎就绪' 'S18c 在线引擎 sha256 校验通过'
assert_in "$out" '只读诊断模式' 'S18d 在线引擎会话运行'
assert_ni "$out" '无法在本机执行' 'S18e noexec 未误报'

echo '== 8. 临时目录卫生 =='
export MOCK_BALANCE_BODY="$BAL_OK" MOCK_ACTIVATE_CODE=200 MOCK_ACTIVATE_BODY='{"key":"k-x"}'
export MOCK_VERIFY_CODE=200 MOCK_VERIFY_BODY='{"already_verified":true}'
E1="$(mk_usb enterprise)"; printf 'k-x\n' > "$E1/config/auth_token"
w1="$(run_l "$E1" '0\nn\n\n' | sed -n 's/.*会话历史位于 \([^ ]*\).*/\1/p' | head -n1)"
E2="$(mk_usb enterprise)"; printf 'k-x\n' > "$E2/config/auth_token"
w2="$(run_l "$E2" '0\nn\n\n' | sed -n 's/.*会话历史位于 \([^ ]*\).*/\1/p' | head -n1)"
[ -n "$w1" ] && [ -n "$w2" ] && [ "$w1" != "$w2" ] && ok 'S21a 两次运行 WORK 随机不重复' || bad "S21a WORK 不随机（$w1 / $w2）"
rm -rf -- "$w1" "$w2" 2>/dev/null
U="$(mk_usb)"; printf 'k-x\n' > "$U/config/auth_token"; put_engine "$U"
env -u TMPDIR bash -c "printf '%b' '1\\n\\n0\\n\\n' | PATH='$MOCK:$PATH' bash '$U/repair-on-linux.sh' >/dev/null 2>&1" && ok 'S21b TMPDIR 未设时正常跑通' || bad 'S21b TMPDIR 未设'
POST_RESIDUE="$(ls -d "${TMPDIR:-/tmp}"/ai-repair.* 2>/dev/null | sort)"
if [ "$PRE_RESIDUE" = "$POST_RESIDUE" ]; then ok 'S21d 无 /tmp/ai-repair.* 残留'; else bad "S21d 有残留: $(printf '%s' "$POST_RESIDUE" | tr '\n' ' ')"; fi

# ---------------- 清理与汇总 ----------------
rm -rf -- "${TMPDIR:-/tmp}"/fakeusb.* "$MOCK" "${MOCK2:-}" "${BARE:-}" 2>/dev/null
echo ""
printf '=============================================\n'
printf '  repair-on-linux 冒烟: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
printf '=============================================\n'
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
