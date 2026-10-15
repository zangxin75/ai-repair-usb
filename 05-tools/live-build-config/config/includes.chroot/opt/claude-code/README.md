# opt/claude-code —— Claude Code 离线安装（占位）

**此目录在构建时由 build.sh 自动填充，请勿手工放文件。**

## 来源与流程

1. build.sh 在构建机联网环境下，用 cache 中 Node tarball 自带的 npm 在 staging 目录执行：
   `npm install @anthropic-ai/claude-code`（版本可在 build.sh 顶部 `CLAUDE_CODE_VERSION` 锁定）。
2. 将 staging 的 `node_modules/` + `package.json` + **`package-lock.json`（版本锁定依据）** 整体拷入本目录。
3. Live 系统内可执行入口为 `/opt/claude-code/node_modules/.bin/claude`。
4. hook `0200-claude-code-setup.hook.chroot` 建立 `/usr/local/bin/claude` 软链、构建期验证 `claude --version`，并把版本号固化到 `/etc/ai-repair-version`。

## 为什么这样装

- 设计 §2.2.2：离线安装方式 = 联网构建机 npm install 后整体拷贝 node_modules，package-lock 锁定版本，构建脚本固化——Live 侧零网络依赖、版本可复现。
- 运行期升级走 U 盘 `/config/claude-code-latest.tar.gz`（update-claude.sh + welcome.sh 解包回退机制，设计 §2.2.3），与本目录的 ISO 内置版互不影响。
