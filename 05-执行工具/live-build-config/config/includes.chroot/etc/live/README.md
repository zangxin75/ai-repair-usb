# etc/live —— 自动登录配置（占位说明）

live 用户无密码自动登录**不在此放静态配置文件**，由构建期 hook 完成（确定性更高、与用户/密码改动集中在一处）：

- `config/hooks/live/0300-autostart.hook.chroot`：
  - `passwd -d live` 清空 live 用户密码（配合 auto/config 的 `username=live` 启动参数）
  - 写 `/etc/lightdm/lightdm.conf.d/50-autologin.conf`：`autologin-user=live`、`autologin-user-timeout=0`
  - 写 `/etc/xdg/autostart/ai-repair-welcome.desktop`：进 Xfce 后全屏 xfce4-terminal 执行 welcome.sh

此目录仅作占位，保留给未来需要的 live-config 静态覆盖文件（如 `/etc/live/config.conf.d/`）。
