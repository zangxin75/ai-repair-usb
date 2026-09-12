#!/usr/bin/env bash
# build.sh —— AI-Repair-Live ISO 构建入口（P2-L6）
#
# 流程：
#   ① 依赖检查（lb / curl / tar / xz / sha256sum）
#   ② 同步 ../build/live/ 脚本与任务文本 → config/includes.chroot/（拷贝，非软链）
#   ③ 下载 Node 20 LTS tarball 到 cache/，解压填充 config/includes.chroot/opt/node/
#   ④ 构建机联网 npm install claude-code → 填充 config/includes.chroot/opt/claude-code/
#   ⑤ lb config && lb build（需 root）
#   ⑥ 产物改名带版本号 + 生成 .sha256，输出到 ../dist/
#
# 用法：bash build.sh          # 完整构建
#       bash build.sh --deps   # 只跑 ①-④（准备离线组件，不构建 ISO）
set -euo pipefail

# ===== 版本与命名（升级时改这里；与 auto/config 的 --image-name 保持一致） =====
IMAGE_VERSION="v0.1"
IMAGE_DATE="20260912"
IMAGE_NAME="AI-Repair-Live-${IMAGE_VERSION}-${IMAGE_DATE}"

# ===== 离线组件版本 =====
NODE_VERSION="20.18.0"        # Node 20 LTS；升级时改这里
NODE_TARBALL="node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
CLAUDE_CODE_VERSION=""        # 空 = npm 最新版；锁版本填如 "1.0.0"

# ===== 路径 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_SRC="$SCRIPT_DIR/../build/live"              # 维修脚本权威源（P3/P3.5 开发目录）
INCLUDES="$SCRIPT_DIR/config/includes.chroot"
CACHE_DIR="$SCRIPT_DIR/cache"
DIST_DIR="$SCRIPT_DIR/../dist"

say() { echo; echo "==> $*"; }

# ===== ① 依赖检查 =====
say "第1步：依赖检查"
MISSING=()
for cmd in lb curl tar xz sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "缺少命令：${MISSING[*]}" >&2
    echo "Debian 12 构建机安装：" >&2
    echo "  apt install live-build git curl jq squashfs-tools xorriso isolinux syslinux-efi grub-pc-bin grub-efi-amd64-bin mtools dosfstools xz-utils" >&2
    exit 1
fi
echo "    依赖齐全。"

# ===== ② 同步 build/live 脚本 → includes.chroot =====
say "第2步：同步 ../build/live/ → config/includes.chroot/"
if [[ -d "$LIVE_SRC" ]]; then
    # cp 拷贝而非软链：软链会把构建机绝对路径带进 ISO（chroot 内必断）
    # 只同步 build/live 下存在的子树（usr/local/bin、usr/local/share/tasks 等），不动 opt/
    (cd "$LIVE_SRC" && find . -mindepth 1 -maxdepth 1 -exec cp -a {} "$INCLUDES/" \;)
    echo "    已同步：$(cd "$LIVE_SRC" && find . -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null || true)"
else
    echo "    警告：$LIVE_SRC 不存在，跳过脚本同步（P3 脚本尚未开工？）" >&2
fi

# ===== ③ Node tarball 下载与填充 =====
say "第3步：Node.js ${NODE_VERSION} tarball"
mkdir -p "$CACHE_DIR"
if [[ ! -f "$CACHE_DIR/$NODE_TARBALL" ]]; then
    echo "    下载 $NODE_URL"
    curl -fL --retry 3 -o "$CACHE_DIR/$NODE_TARBALL" "$NODE_URL"
else
    echo "    命中缓存：cache/$NODE_TARBALL"
fi
# 解压到 cache/node（复用；版本变化时重建）
if [[ ! -x "$CACHE_DIR/node/bin/node" ]] || [[ "$("$CACHE_DIR/node/bin/node" --version)" != "v${NODE_VERSION}" ]]; then
    rm -rf "$CACHE_DIR/node"
    mkdir -p "$CACHE_DIR/node"
    tar -xJf "$CACHE_DIR/$NODE_TARBALL" -C "$CACHE_DIR/node" --strip-components=1
fi
# 填充 includes（保留 README.md，只清 bin/lib 等运行时目录）
rm -rf "$INCLUDES/opt/node/bin" "$INCLUDES/opt/node/lib" "$INCLUDES/opt/node/include" "$INCLUDES/opt/node/share"
cp -a "$CACHE_DIR/node/bin" "$CACHE_DIR/node/lib" "$CACHE_DIR/node/include" "$CACHE_DIR/node/share" "$INCLUDES/opt/node/"
echo "    Node $(/opt/node/bin/node --version 2>/dev/null || "$INCLUDES/opt/node/bin/node" --version) 已填充到 includes.chroot/opt/node/"

# ===== ④ claude-code 依赖（构建机联网 npm install） =====
say "第4步：claude-code npm 依赖"
STAGING="$CACHE_DIR/claude-code-src"
mkdir -p "$STAGING"
export PATH="$CACHE_DIR/node/bin:$PATH"   # 用 tarball 自带 npm，构建机无需另装 Node
if [[ -f "$STAGING/package-lock.json" ]]; then
    # 已有锁文件：npm ci 严格复现
    (cd "$STAGING" && npm ci --omit=dev)
else
    # 首次：安装并生成 package-lock.json（版本锁定依据，设计 §2.2.2）
    PKG="@anthropic-ai/claude-code"
    [[ -n "$CLAUDE_CODE_VERSION" ]] && PKG="$PKG@$CLAUDE_CODE_VERSION"
    (cd "$STAGING" && npm init -y >/dev/null && npm install --omit=dev "$PKG")
fi
rm -rf "$INCLUDES/opt/claude-code/node_modules"
cp -a "$STAGING/node_modules" "$STAGING/package.json" "$STAGING/package-lock.json" "$INCLUDES/opt/claude-code/"
echo "    claude-code 已填充到 includes.chroot/opt/claude-code/（package-lock.json 锁版本）"

if [[ "${1:-}" == "--deps" ]]; then
    say "已完成离线组件准备（--deps 模式，跳过 ISO 构建）"
    exit 0
fi

# ===== ⑤ lb config && lb build =====
say "第5步：lb config && lb build"
if [[ "$(id -u)" -ne 0 ]]; then
    echo "lb build 需要 root 权限，请用 sudo bash build.sh 运行（①-④ 步骤可用普通用户先跑）" >&2
    exit 1
fi
lb config
lb build

# ===== ⑥ 产物改名 + SHA256 → ../dist/ =====
say "第6步：产物整理"
LB_PRODUCT="$SCRIPT_DIR/${IMAGE_NAME}-amd64.hybrid.iso"
[[ -f "$LB_PRODUCT" ]] || { echo "未找到 lb 产物：$LB_PRODUCT" >&2; exit 1; }
mkdir -p "$DIST_DIR"
mv -f "$LB_PRODUCT" "$DIST_DIR/${IMAGE_NAME}.iso"
(cd "$DIST_DIR" && sha256sum "${IMAGE_NAME}.iso" > "${IMAGE_NAME}.iso.sha256")
echo "    产物：$DIST_DIR/${IMAGE_NAME}.iso"
echo "    校验：$DIST_DIR/${IMAGE_NAME}.iso.sha256"

say "构建完成：${IMAGE_NAME}.iso"
