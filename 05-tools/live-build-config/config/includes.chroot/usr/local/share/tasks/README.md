# usr/local/share/tasks —— 主菜单任务文本（占位，P3.5 交付）

主菜单选项 1-5 对应的固化流程任务描述文本（设计 §2.6.5），main-menu.sh 以初始 prompt 形式传给 claude：

```bash
exec claude "$(cat /usr/local/share/tasks/tijian.txt)"
```

## 预期内容（P3.5-M1）

`tijian.txt`（电脑体检） `reinstall.txt`（重装系统） `password.txt`（密码重置） `backup.txt`（备份/抢救文件） `hardware.txt`（硬件检测）

## 约定

- 首行统一加前缀「（系统流程，请直接开始执行，不要复述任务）」，避免 claude 把任务描述当闲聊回应。
- 权威源在 `../../build/live/usr/local/share/tasks/`，本目录由 build.sh 同步（与 usr/local/bin 同一机制）。
