# AI Repair USB — a whole AI repair shop on one stick 🛠️

> Boot a dead PC into a Chinese-language AI repair system. Plug the same stick into a healthy PC and get a portable AI workstation — Claude Code, Codex CLI, and more, zero install, zero residue. **Your tools follow you, not your machines.**

[![CI](https://github.com/zangxin75/ai-repair-usb/actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml) [![Release](https://img.shields.io/badge/release-v0.3-blue.svg)](../../releases) [![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE) [![简体中文](https://img.shields.io/badge/README-简体中文-red.svg)](README.zh-CN.md)

**One stick, four jobs:**

| | What it does |
|---|---|
| 🔧 **AI Repair Engineer** | PC won't boot / BSOD loop / forgotten password / BitLocker? Boot from the stick into a Debian 12 live system with a conversational AI that walks you through disk checks, data rescue, password resets, and reinstalls. Dangerous operations always require explicit confirmation. |
| 📄 **Office Assistant** | On a healthy PC, double-click `AI-Workstation` and pick the office-assistant mode: drafts, Excel formulas, email polish, report formatting. No admin rights, no system changes — safe on a borrowed laptop. |
| 💻 **Install Master** | Windows 10/11 ISOs are fetched live from Microsoft's official servers (we never redistribute a single Microsoft byte); Debian 12 netinst ships on the stick. |
| 🤖 **Portable AI agents** | Codex CLI, OpenClaw and Pi ride along, pre-wired to any Anthropic/OpenAI-compatible gateway. Plug into any PC and start coding. |

## Quick start

**Windows** (admin PowerShell, blank USB stick ⚠️ will be wiped):

```powershell
irm https://usb.tokeneff.com/maker/usb-v1.0.ps1 | iex
```

**Linux / macOS:**

```bash
curl -sL https://usb.tokeneff.com/maker/usb-v1.0.sh | sudo bash
```

Prefer to audit first? `curl -sLO https://usb.tokeneff.com/maker/usb-v1.0.sh && less usb-v1.0.sh` — every component is pinned with a SHA256.

The maker asks you to check boxes for what you want (Claude Code / Codex / Windows ISO / Debian), verifies free AI credits against your email, and flashes everything via Ventoy — resumable, no babysitting.

## Use your own key / self-hosted gateway

The stick talks to any Anthropic-compatible endpoint (we run one at tokeneff.com with free weekly credits, but it is optional):

```bash
export ANTHROPIC_BASE_URL=https://your-gateway.example.com
export ANTHROPIC_AUTH_TOKEN=sk-your-key
```

See [docs/self-hosted-gateway.md](docs/self-hosted-gateway.md) for a 10-minute LiteLLM setup.

## Why not just…?

| | micro-PE / FirPE | bare Ventoy | manual Claude Code |
|---|---|---|---|
| AI-guided repair, conversational | ❌ | ❌ | ❌ |
| Works on a dead PC | ❌ (WinPE tools, no AI) | ❌ | ❌ |
| Zero install on a healthy PC | n/a | n/a | ❌ |
| Chinese-first UX | ✅ | menus | terminal |
| Restore/reinstall Windows + Debian | ✅ | manual | ❌ |

## Reproduce the ISO

```bash
sudo bash setup-build-host.sh      # Debian 12 build host
cd live-build-config && sudo bash build.sh
bash tests/smoke.sh                # 15/15 no-hardware smoke tests
```

Full story in [05-执行工具/](05-执行工具/) (Chinese; English docs in progress — PRs welcome!).

## Safety & disclaimer

- The one-liner installers execute remote scripts — audit them first if that bothers you; static copies are always at the same URLs.
- Repair operations that write to a disk always show a plan and ask for confirmation. Still: **back up before you repair.**
- Windows ISOs come straight from Microsoft's official download service at run time; this project distributes no Microsoft content.

## Roadmap

- [x] v0.1 — first bootable ISO (Claude Code + Chinese repair menus)
- [x] v0.3 — built-in Claude skill set (smart-diagnosis / data-rescue / …), desktop launcher, one-line makers for Win/Linux
- [x] v0.3.x — Codex CLI component, Windows-side AI-Workstation launcher
- [ ] v0.4 — portable Node + OpenClaw + Pi (portable multi-agent workstation)
- [ ] WinPE builder, repair-record system, English docs

See [01-项目规划/README.md](01-项目规划/README.md) for the full plan (Chinese).

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The smoke suite runs without any hardware, so you can validate a change in five minutes.

## License

[MIT](LICENSE). Ventoy and other bundled upstream components keep their own licenses.
