# Base research and architecture rationale (2026-07-16)

Goal: a minimal box where the user signs in to Steam and runs **TBH: Task Bar Hero**,
with full access for any AI (programmatic screenshot + mouse/keyboard).
Host: Windows 11 Pro.

## The game (verified facts)

- **TBH: Task Bar Hero** — Steam app `3678970`, free-to-play, Unity, DX11, Windows-only.
  https://store.steampowered.com/app/3678970/
- **Not truly offline**: chest and item drops are validated server-side (the items are
  tradable on the Steam Market). Offline play only yields XP and gold. **The box needs internet.**
- **Does not depend on the real Windows taskbar**: it is an always-on-top Unity window (~100 px)
  that the user positions over the taskbar. Evidence: Steam Deck "Playable", ProtonDB **Gold/Platinum**
  → it runs on Linux + Proton.
- No third-party DRM and no kernel-level anti-cheat; but there is server-side validation and a
  real-money marketplace → **automating gameplay with injected input carries a ToS/ban risk.**
- Official requirements: 8 GB RAM / GTX 750 Ti / 2 GB disk (inflated relative to the window size).
- Steam Cloud for saves (progress survives box wipes).

## Candidate ranking (31 evaluated)

| Score | Project | Role | Summary |
| --- | --- | --- | --- |
| 8.0 | [trycua/cua](https://github.com/trycua/cua) (~20k★) | AI framework + box | Full computer-use (screenshot/mouse/keyboard API, MCP server, any LLM). On Windows: a Windows Sandbox provider (minimal but ephemeral) or QEMU (persistent, heavy). Its `computer-server` installs on any VM. |
| 7.5 | [kasmweb/steam](https://github.com/kasmtech/workspaces-images) (Kasm) | Linux box | A single `docker run` → web desktop with Steam. For this game: add a Dockerfile with mesa-vulkan + seccomp for Proton. Software rendering. No default VNC (drive it via Playwright or an HTTP screenshot API). No standalone audio. |
| 7.5 | Windows Sandbox + `wsb` CLI (native Win11 Pro) | Windows box | The most minimal option available: zero installation, boots in seconds, vGPU DX11, networking by default. **Ephemeral**: Steam disappears on close (mitigation: a mapped folder with a portable Steam; risk of re-triggering Steam Guard on every boot). |
| 7.0 | [dockur/windows](https://github.com/dockur/windows) (52k★) | Windows box | Real Windows 11 in Docker (KVM via WSL2, nested virtualization). Guaranteed compatibility, persistent Steam login. Built-in AI access: noVNC :8006, raw VNC via `ARGUMENTS='-vnc :0'`, RDP :3389. Heavy: 7.9 GB image, 6-8 GB RAM, software DX11 (WARP). |
| 7.0 | [fdcastel/Hyper-V-Automation](https://github.com/fdcastel/Hyper-V-Automation) | Windows box | Scripted persistent Hyper-V VM (unattended Windows install). Best Steam persistence + checkpoints. AI layer is 100% DIY (PS Direct → install MCP/VNC in the guest). |
| 6.5 | [CursorTouch/Windows-MCP](https://github.com/CursorTouch/Windows-MCP) (6.4k★) | AI layer | 23 MCP tools (dxcam Screenshot, Win32 Click/Type, PowerShell...) over stdio or streamable-http with auth. Not a box — it is the access layer that goes INSIDE the Windows box. Works on the game via vision + coordinates (UIA cannot see Unity). |
| 6.0 | Steam-Headless, selkies, OSWorld, Apollo, linuxserver/webtop | alternatives | Viable but worse on this host (designed for bare-metal Linux hosts or GPU passthrough). |

Discarded (score ≤5): bytebot, anthropic computer-use-demo (reference, not a product), wolf/gow
(require a Linux host), quickemu, Sunshine/Moonlight (streaming for humans, not for AI), e2b (paid cloud).

## Possible architectures

1. **Maximum compatibility (recommended)**: `dockur/windows` (real Win11, persistent) + Windows-MCP
   inside the guest (HTTP+auth) and/or built-in VNC → any AI controls it via MCP or VNC.
2. **Minimal resource use**: Kasm `steam` + Proton (the game is ProtonDB Gold) — a lightweight Linux
   container, but it requires image customization and input access goes through a browser driver.
3. **Minimal setup**: Windows Sandbox (+ cua or Windows-MCP bootstrapped by a LogonCommand) —
   disposable; accept a Steam re-login per session.

## Decision

Nexo Box uses architecture 1: `dockur/windows` + Windows-MCP. The deciding factors:

- **Windows compatibility is guaranteed.** The game is Windows-only, and a real Windows 11 guest
  removes any Proton/Wine risk. Architectures 2 and 3 trade this away for lower weight or setup.
- **Steam login persists.** dockur/windows keeps a persistent disk, so the Steam session (and Steam
  Guard) survives reboots. Windows Sandbox is ephemeral and would force a re-login every session.
- **AI access is built in and flexible.** noVNC (:8006), raw VNC, and RDP (:3389) ship out of the box,
  and Windows-MCP adds programmatic tools (screenshot + mouse/keyboard + PowerShell) over authenticated
  HTTP inside the guest. Because the game is a Unity window that UIA cannot inspect, Windows-MCP drives
  it by vision + coordinates, which it supports.
- **The cost is acceptable.** The trade-off is weight (a 7.9 GB image, 6-8 GB RAM, software DX11/WARP),
  but the game's real footprint is small and software rendering is enough for a ~100 px always-on-top window.

In short: Windows-MCP is the AI-access layer placed inside the box, and dockur/windows is the box.
Together they provide a disposable, persistent-enough, fully AI-controllable Windows environment.
