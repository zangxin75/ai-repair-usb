# Reproduce the repair-system ISO (stranger's view)

Goal: build an `AI-Repair-Live-*.iso` from source on a Debian 12 host, byte-equivalent to the official release. WSL2 is **not** supported (no loop device).

> Chinese version of this guide: [reproduce-iso.zh-CN.md](reproduce-iso.zh-CN.md).

## 0. Prerequisites

- Debian 12 x86_64 host, ≥40 GB free disk, network access to a Debian mirror
- This repository cloned

```bash
git clone https://github.com/zangxin75/ai-repair-usb.git && cd ai-repair-usb
```

## 1. Build-host dependencies

```bash
sudo bash setup-build-host.sh
```

Installs `live-build`, kernel/firmware, `squashfs-tools`, `xorriso`, and other build deps. Idempotent — re-runnable.

## 2. Build

```bash
cd 05-tools/live-build-config
sudo bash build.sh            # first run ~30-60 min (network-bound)
```

If you modified `hooks/` or `package-lists/`, clear stale state first (keep the cache):

```bash
sudo rm -rf .build chroot binary*
sudo bash build.sh
```

Output lands in `images/` (or the build's output dir) with an `.sha256` sidecar.

## 3. Verify

```bash
sha256sum -c *.sha256
# Spot-check key contents (kernel / squashfs / claude-code binary on the stick)
```

## 4. Known pitfalls (from the field)

| Pitfall | Fix |
|---|---|
| `deb.debian.org` is painfully slow from China | `auto/config` is pinned to a domestic mirror — don't switch it back |
| `claude-code` 2.x is a native ELF (Bun-built, ~235 MB); the npm main tarball only has a 500 B placeholder | `build.sh` uses `npm install` so the postinstall hook assembles the platform package `@anthropic-ai/claude-code-linux-x64` automatically. For manual paths see `update-claude.sh` (size check >10 MB guards against placeholder leakage) |
| The `live` user is created by live-config on **first boot**, not during chroot | Don't `passwd` / `useradd` it in hooks — the scripts use an `id` idempotency guard |
| `firmware-mediatek` doesn't exist on bookworm | Use `firmware-misc-nonfree` instead |

## 5. Don't want to build the ISO? Just exercise the scripts

```bash
cd 05-tools && bash tests/smoke.sh   # 15 assertions, all mocked, same suite CI runs
```

## See also

- [README.md](../README.md) — project overview, quick start
- [docs/self-hosted-gateway.md](self-hosted-gateway.md) — 10-minute LiteLLM setup
