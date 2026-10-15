# opt/node —— Node.js 20 LTS 离线预置（占位）

**此目录在构建时由 build.sh 自动填充，请勿手工放文件。**

## 来源与流程

1. build.sh 从 nodejs.org 下载官方 tarball（如 `node-v20.x.x-linux-x64.tar.xz`）到本仓库 `cache/`（下载一次，后续构建复用）。
2. 解压后整体拷入本目录，使 Live 系统内路径为 `/opt/node/bin/node` 等。
3. hook `0100-node-setup.hook.chroot` 负责配 PATH（/etc/profile.d + /usr/local/bin 软链）并构建期验证 `node --version`。

## 设计依据

- 技术方案 V1.5 §2.2.2：Node.js 20 LTS 离线 tarball 预置，为 Claude Code 运行依赖。
- 版本号在 build.sh 顶部 `NODE_VERSION` 修改。
