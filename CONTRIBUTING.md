# Contributing

感谢关注 AI 电脑维修 U盘！

## 五分钟上手（无需任何硬件）

```bash
git clone https://github.com/zangxin75/ai-repair-usb.git
cd ai-repair-usb/05-tools
bash tests/smoke.sh        # mock 冒烟测试，不碰真机/U盘
```

改动 `.sh` / `.ps1` 后请先过静态检查：

```bash
bash -n <script>
shellcheck <script>
```

## PR 约定

1. Fork + feature branch，PR 到 `main`。
2. 标题格式：`[模块] 摘要`，模块取值：live / maker / launcher / gateway / docs / iso。
3. 涉及行为变更请补 smoke 断言（`tests/smoke.sh` 对应小节）。
4. **不得提交**任何真实凭证、内网地址、付费组件字节。
5. 文档：中文为主，新增文档放 `01-planning ~ 06-会议记录`（见仓库规范），根目录只放 README/LICENSE。

## Issue 模板

- Bug：系统/机器型号、制作器版本（manifest version）、`smoke.sh` 是否复现、截图。
- 功能：先查 [01-planning/README.md](01-planning/README.md) 路线图，避免重复。

## 行为准则

友好、就事论事；维修有风险，回答请附「先备份」提醒。
