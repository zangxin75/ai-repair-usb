# config/includes.chroot —— 打进 ISO 根文件系统的文件（P2-L2b）

此目录内容在构建时被原样拷入 Live 系统根目录（/）。**注意：构建期注入的大文件（Node、claude-code）由 build.sh 自动填充，不要手工提交大文件到本仓库。**

| 路径 | 内容来源 | 说明 |
|------|---------|------|
| `opt/node/` | build.sh 下载 Node 20 LTS 官方 tarball 解压填充 | 离线预置，见 opt/node/README.md |
| `opt/claude-code/` | build.sh 在构建机联网 `npm install` 后整体拷贝 node_modules | 版本由 package-lock.json 锁定，见 opt/claude-code/README.md |
| `usr/local/bin/` | `../../build/live/usr/local/bin/` 维修脚本 | **由 build.sh 每次构建时拷贝同步（不是软链）**，见 usr/local/bin/README.md |
| `usr/local/share/tasks/` | 任务文本（P3.5 交付，菜单 → claude 初始 prompt，设计 §2.6.5） | 见 usr/local/share/tasks/README.md |
| `etc/skel/.claude/CLAUDE.md` | 本仓库手工维护 | AI 维修助手系统提示词，新用户骨架（live 用户家目录模板） |
| `etc/xdg/autostart/fcitx5.desktop` | 本仓库手工维护 | fcitx5 输入法自启动 |
| `etc/live/` | 占位说明 | 自动登录实际由 hook 0300 写 lightdm 配置完成，见 etc/live/README.md |

## 同步关系（重要）

- 脚本与任务文本的**唯一权威源**在 `../../build/live/`（P3/P3.5 在那里开发），本目录只是构建期的拷入点。
- 每次 `build.sh` 运行都会重新同步，直接改本目录的脚本会在下次构建被覆盖。
