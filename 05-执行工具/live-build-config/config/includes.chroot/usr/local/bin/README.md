# usr/local/bin —— 维修脚本拷入点（占位）

**此目录内容由 build.sh 每次构建时从 `../../build/live/usr/local/bin/` 拷贝同步，请勿在此直接编辑。**

## 同步方式

- 权威源：`../../build/live/usr/local/bin/`（P3 脚本开发目录，git 管理）。
- 同步：**构建脚本用 cp 拷贝，不是软链**——软链会把构建机绝对路径带进 ISO，chroot 内必断。
- 每次 build.sh 运行都重新同步，本目录的本地改动会被覆盖。

## 预期内容（P3 交付清单，设计 §2.2.3）

`welcome.sh`（已有） `check-network.sh` `mount-ventoy-data.sh` `disk-check.sh` `bitlocker-unlock.sh` `win-reset-password.sh` `backup-user-data.sh` `install-windows.sh` `main-menu.sh` `offline-menu.sh` `update-claude.sh`
