# AI 电脑维修 U盘 · 项目 README

- **创建日期**: 2026-09-12
- **最后更新**: 2026-10-13
- **版本**: V1.0
- **状态**: 审核中
- **作者**: Claude

## 项目概述

制作一个支持系统启动的多功能 U 盘：集成 Windows 10/11 安装镜像、Claude Code 及其依赖。U盘启动后自动进入 Claude Code 中文交互界面，服务三类用户：家庭用户（日常维护自救）、上门维修人员（现场诊断维修）、装机人员（新机快速部署）。

## 关键文档索引

| 文档 | 位置 | 状态 |
|------|------|------|
| 总体设计方案 | [04-design/技术方案_AI电脑维修U盘_总体设计_20260912.md](../04-design/技术方案_AI电脑维修U盘_总体设计_20260912.md) | **V1.5 最终定稿**（critic 三轮审计：6.0 → 8.0 → 7.0 → 8.5 通过） |
| 实施计划 | [05-tools/实施计划_AI电脑维修U盘_20260912.md](../05-tools/实施计划_AI电脑维修U盘_20260912.md) | **V1.4 最终定稿**（critic 审计通过，8.5/10） |
| 场景三新增功能方案 | [04-design/技术方案_AI电脑维修U盘_场景三Windows在线维修新增功能_20261013.md](../04-design/技术方案_AI电脑维修U盘_场景三Windows在线维修新增功能_20261013.md) | **V1.2 定稿**（critic 审计 REVISE 7.0 → ACCEPT 8.5；V1.1 改邮箱验证码；V1.2 delta 复审修复：portal 无现成邮件通道 → 新建 SMTP） |
| 场景三实施计划 | [05-tools/实施计划_AI电脑维修U盘_场景三新增功能_20261013.md](../05-tools/实施计划_AI电脑维修U盘_场景三新增功能_20261013.md) | **V1.2 定稿**（critic 6.9 REVISE 逐项闭环 + delta 复审 6.5 REVISE 全部修复；三线并行，8-10 天；里程碑 M1=S2 上线 / M2=T1 通过） |
| 开源引流改造方案 | [04-design/实施方案_GitHub仓库开源引流改造_20261015.md](../04-design/实施方案_GitHub仓库开源引流改造_20261015.md) | V1.0 待审计（S1 敏感出仓 → S2 README 双语 → S3 Release/CI → S4 复现文档 → S5 v0.4 转 public 首发；3.5 天，S5 依赖 P-B） |

## 进度跟踪

- [x] 需求分析（含 tokeneff.com 网关接入、一键制作、选择式交互三轮补充需求）
- [x] 总体设计方案（V1.0 → 三轮审计修订 → **V1.5 定稿**）
- [x] 实施计划（V1.0 → 三轮审计修订 → **V1.4 定稿**）
- [ ] P0 环境准备 + 测试环境预制（**构建机依赖已装毕**；待备：U盘/测试机）
- [ ] P0.5 关键技术 Spike（**S3 网关验证 ✅ 通过**：连通/鉴权/SSE 流式全绿，详见 [05-tools/P0.5-Spike验证报告_网关连通性_20260912.md](../05-tools/P0.5-Spike验证报告_网关连通性_20260912.md)；其余项待硬件）
- [ ] P1 ~ P8 实施（总周期 17-27 个工作日）
  - [x] 软件交付物开发完成（Live 脚本 17 文件 / 制作端 5 文件 / live-build 骨架 16 文件 / 冒烟测试 1 套）
  - [x] verifier 独立验证（首轮 FAIL：2 高危 + 3 中危；修复后复验 **PASS**，冒烟测试 15/15 全绿）
  - [x] 首版 ISO 构建成功（**AI-Repair-Live-v0.1-20260912.iso，1.4GB**，构建机 四轮排雷后产出：中国镜像 / bookworm 固件包名 / claude-code 2.x 原生二进制 / live 用户时序 / lb 脏状态；sha256 已校验，内核+initrd+squashfs+16 个维修脚本+任务文本+claude-code 均验证在盘）
  - [x] **v0.3 发布（2026-10-15）**：AI-Repair-Live-v0.3-20261014.iso（1.5GB，sha256 已校验）— 内置 Claude 技能集（smart-diagnosis / data-rescue / systematic-debugging / verification-before-completion，随 ISO 静态分发）+ Token 签发与桌面直启；manifest 1.0.3 + 制作器 usb-v1.0.sh v1.1.0 已上线 usb.tokeneff.com，全链路（manifest / maker 脚本 / ISO / .sha256）线上 200 验证通过。技能热更新因 exFAT /config 供应链风险延后（见 P-A 计划）
  - [x] **P-A 实施（2026-10-15，A1~A5 全部完成）**：启动器 repair-on-windows.ps1 0.3.0（模式菜单先于提权：维修按需 UAC / 办公助手免提权 / Codex 入口按 agents.json 显隐 / Claude 未装不回落）；双入口 AI-Workstation.bat（与 bat 逐字节一致）+ 办公人格 office-CLAUDE.md；制作器 1.2.0 双侧（勾选交互 + 两段容量预检 MinBaseGB=5 + agents.json/isos.json + Debian netinst + ventoy 别名 + codex 落盘链路）；smoke 第 6 节 7 项断言（29/29 通过）。**A1 网关真 key 复测通过**（测试 key 四端点全 200：chat glm-4-flash/air、messages claude→glm-5.2、responses glm-5.2、/api/usb/balance 周额度扣减正常；排雷三层：portal usb_free credit 惰性授信 / plans.usb-free 月软上限 0=全拒改 20000 / usb 套餐与批次白名单补 glm-5.2——Claude Code 映射落点，缺它 Live 端全挂，详见 P-A 计划 A1 节）。**A3 Codex 上线**：codex.exe v0.162.1（官方 npm 包取源，国内镜像 9MB/s）自托管 /downloads/，manifest 1.0.4 已部署 usb.tokeneff.com，Linux 版真实会话经网关验证输出正常。余项：真机验收 K1a（用户）
  - [ ] 真机启动测试（待 U盘/测试机）
- [ ] 场景三（Windows 在线维修）新功能：① repair-on-windows.ps1 启动器 → ② 维修记录系统（customer/enterprise 双模式）+ 机器指纹召回 → ④ 凭证残留策略 → ⑤ 任务文本环境感知增强 → ⑥ tokeneff key 激活发放与引流转化（激活制 + 分层验证 + 并发限额 + 推广码分成，方案见 04-design/技术方案_AI电脑维修U盘_场景三Windows在线维修新增功能_20261013.md）

## 文档目录说明

- `01-planning/` — 本文件、项目总结、交付清单
- `02-市场调研/` — 竞品分析（如微PE、FirPE、Ventoy 生态）
- `03-内容策略/` — （本项目暂不使用）
- `04-design/` — 总体设计、详细技术方案
- `05-tools/` — 实施计划、构建脚本、配置清单
- `06-会议记录/` — 决策记录
- `99-参考文档/` — 参考资料、过期版本
