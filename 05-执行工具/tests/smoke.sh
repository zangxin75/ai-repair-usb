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

echo
echo "=== 结果：通过 $PASS 项 / 失败 $FAIL 项 ==="
[[ $FAIL -eq 0 ]] || exit 1
