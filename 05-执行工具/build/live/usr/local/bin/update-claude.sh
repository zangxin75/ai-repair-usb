#!/usr/bin/env bash
# update-claude.sh —— Claude Code 版本检查与离线更新包下载
#
# 用途：联网检查 npm 上 @anthropic-ai/claude-code 最新版 → 与当前版本对比 →
#       有新版则下载并打成 tar.gz 存到 /mnt/ventoy/config/claude-code-latest.tar.gz。
#       （exFAT 不支持 Unix 权限与符号链接，node_modules 树不能直接落 exFAT，
#         必须打包存储 —— 设计 §2.2.3；welcome.sh 启动时解包到可写层优先加载，
#         解包失败静默回退 ISO 内置版）
#
# 调用方：用户手动、维修人员定期维护
# 依赖命令：curl npm node tar mount-ventoy-data.sh whiptail
set -euo pipefail

PKG_NAME="@anthropic-ai/claude-code"
VENTOY_MNT="/mnt/ventoy"
OUT_PKG="$VENTOY_MNT/config/claude-code-latest.tar.gz"
NPM_REGISTRY="https://registry.npmjs.org"

show_help() {
    cat <<'EOF'
用法: update-claude.sh
联网检查 AI 助手（claude-code）是否有新版本；有则下载打包存到 U盘
config/claude-code-latest.tar.gz，下次启动自动加载新版。
EOF
}
[[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

mountpoint -q "$VENTOY_MNT" 2>/dev/null || mount-ventoy-data.sh || {
    echo "无法挂载数据分区。" >&2; exit 1; }
mkdir -p "$VENTOY_MNT/config"

# 当前版本（可能来自解包优先加载路径或 ISO 内置）
CURRENT=$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
echo "当前版本：$CURRENT"

# npm 最新版本
LATEST=$(curl -s --max-time 15 "$NPM_REGISTRY/$PKG_NAME/latest" 2>/dev/null \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' | head -1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
[[ -n "$LATEST" ]] || { echo "无法获取最新版本信息（网络问题或 npm 源不可达）。" >&2; exit 1; }
echo "最新版本：$LATEST"

if [[ "$CURRENT" == "$LATEST" ]]; then
    echo "已是最新版本，无需更新。"
    exit 0
fi

# 版本比较（简单点分十进制）
newer() {  # newer A B → A > B ?
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" != "$1" ]
}
if ! newer "$LATEST" "$CURRENT"; then
    echo "当前版本不旧于最新版本，无需更新。"
    exit 0
fi

echo "发现新版本 $LATEST，正在下载…"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
if command -v npm >/dev/null 2>&1; then
    npm install --prefix "$WORK/pkg" "$PKG_NAME@$LATEST" >/dev/null
    CLI="$WORK/pkg/node_modules/$PKG_NAME/cli.js"
else
    # 无 npm 时直接下 tarball
    curl -sL --max-time 300 "$NPM_REGISTRY/$PKG_NAME/-/claude-code-$LATEST.tgz" -o pkg.tgz
    mkdir -p "$WORK/pkg" && tar -xzf pkg.tgz -C "$WORK/pkg" && mv "$WORK/pkg/package" "$WORK/pkg/cc"
    CLI="$WORK/pkg/cc/cli.js"
fi
[[ -f "$CLI" ]] || { echo "下载内容不完整。" >&2; exit 1; }

# 打包为 tar.gz（保留可写层解包后可直接使用的结构）
mkdir -p "$WORK/stage/bin" "$WORK/stage/lib"
cp -a "$(dirname "$CLI")" "$WORK/stage/lib/claude-code"
cat > "$WORK/stage/bin/claude" <<'EOF'
#!/usr/bin/env bash
exec node /opt/claude-code-runtime/lib/claude-code/cli.js "$@"
EOF
chmod +x "$WORK/stage/bin/claude"
tar -czf "$OUT_PKG" -C "$WORK/stage" .
chmod 644 "$OUT_PKG" 2>/dev/null || true

echo "更新包已保存：$OUT_PKG（版本 $LATEST）"
echo "下次启动时将自动加载新版本；本次会话仍用当前版本。"
