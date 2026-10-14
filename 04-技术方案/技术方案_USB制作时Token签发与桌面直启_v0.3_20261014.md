# USB 制作时 Token 签发与桌面直启（v0.3 变更方案）

- 创建日期：2026-10-14
- 版本：V1.0
- 状态：已定稿（用户拍板）
- 作者：kt + Claude（ai-repair-usb 会话）

## 背景与目标

K0 实测暴露的首次使用摩擦：开机后要求用户手输网关 token。目标：**token 在制作 U盘 时自动签发写入，开机零配置；桌面一键直启 AI 对话**。原则：AI 时代产品，尽量节约人的心智，让 agent 干活。

## 用户决策记录（2026-10-14）

1. 邮箱验证**提前到制作器阶段**（制作时输邮箱→收验证码→签发 token）。
2. per-USB token 用量上限：**月 1 亿 token，周 2500 万**。
3. 桌面图标**直接进 Claude 对话**（agent 优先，菜单兜底）。
4. 计量保持原计划（token = 影子租户，portal 按 token 归集用量）。
5. 落点按既有结论：portal-backend 独立子模块 `/api/usb/*`，不动 gateway.py。

## 流程

```
制作器(客户机,联网)
  → 输入邮箱 → POST /api/usb/activate/request-code {email}
  → 邮箱收验证码(10分钟有效) → POST /api/usb/activate/verify {email, code}
  → 返回 {usb_token}（影子租户 + LiteLLM key，月1亿/周2500万限额）
  → 制作器写入 U盘 config/auth_token（600，exFAT 尽力）
开机 → welcome.sh 读到 token → 跳过输入 → 直接主菜单
桌面「AI 维修助手」图标 → ai-assistant.sh：有 token 直接 exec claude 对话，无则回退 welcome.sh
```

## 防滥用与兜底

- 验证码：10 分钟有效、60 秒重发间隔、每邮箱 5 次/小时；IP 限频。
- 每邮箱并发有效 USB token 上限（默认 5），超出提示到 portal 管理。
- 制作器离线/无邮箱：跳过，保留现有开机手输流程（welcome.sh 原逻辑不删）。
- token 明文存 exFAT：遗失作废；限额使泄露损失有界。
- 吊销：portal 后台按 token 维度禁用（LiteLLM /key/update）。

## 改动清单

| 位置 | 文件 | 内容 |
|---|---|---|
| portal-backend | app/main.py + migrations | `/api/usb/activate/request-code`、`/verify`；影子租户；限额注入 |
| Live | build/live/.../ai-assistant.sh（新） | 有 token → exec claude；无 → welcome.sh |
| Live | includes.chroot skel Desktop .desktop（新） | 桌面图标 |
| 制作器 | usb-v1.0.ps1 / usb-v1.0.sh | 邮箱+验证码交互（可跳过）+ 写 config/auth_token |
| 文档 | 本文件 + README 进度 | 同步 |

## 版本

进 v0.3（v0.2 = 补浏览器，构建中 2026-10-14）。
