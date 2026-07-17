# Architecture rationale

Goal: a minimal, disposable **Windows desktop** that any AI agent can fully control
(programmatic screenshot + mouse/keyboard), running on a Windows 11 Pro host.

## Options evaluated

| Score | Project | Role | Summary |
| --- | --- | --- | --- |
| 8.0 | [trycua/cua](https://github.com/trycua/cua) (~20k★) | AI framework + box | Full computer-use (screenshot/mouse/keyboard API, MCP server, any LLM). On Windows: a Windows Sandbox provider (minimal but ephemeral) or QEMU (persistent, heavy). Its `computer-server` installs on any VM. |
| 7.5 | Windows Sandbox + `wsb` CLI (native Win11 Pro) | Windows box | The most minimal option: zero installation, boots in seconds, vGPU DX11, networking by default. **Ephemeral**: anything installed disappears on close, so any login must be redone each session. |
| 7.0 | [dockur/windows](https://github.com/dockur/windows) (52k★) | Windows box | Real Windows 11 in Docker (KVM via WSL2, nested virtualization). Guaranteed compatibility with any Windows software, persistent disk. Built-in remote access: noVNC :8006, raw VNC via `ARGUMENTS='-vnc :0'`, RDP :3389. Heavy: 7.9 GB image, 6-8 GB RAM, software DX11 (WARP, no GPU). |
| 7.0 | [fdcastel/Hyper-V-Automation](https://github.com/fdcastel/Hyper-V-Automation) | Windows box | Scripted persistent Hyper-V VM (unattended Windows install). Persistent + checkpoints. AI layer is 100% DIY (PS Direct → install an MCP/VNC server in the guest). |
| 6.5 | [CursorTouch/Windows-MCP](https://github.com/CursorTouch/Windows-MCP) (6.4k★) | AI layer | ~20 MCP tools (dxcam Screenshot, Win32 Click/Type, PowerShell...) over stdio or streamable-http with auth. Not a box — it is the access layer that goes INSIDE the Windows box. Works even on windows with no accessibility tree, via vision + coordinates. |
| 6.0 | selkies, OSWorld, Apollo, linuxserver/webtop, Kasm | alternatives | Viable but worse on this host (designed for bare-metal Linux hosts or GPU passthrough, or they target a Linux desktop rather than Windows). |

Discarded (score ≤5): bytebot, wolf/gow (require a Linux host), quickemu, Sunshine/Moonlight
(streaming for humans, not for AI), e2b (paid cloud).

## Possible architectures

1. **Maximum compatibility (recommended)**: `dockur/windows` (real Windows, persistent) + Windows-MCP
   inside the guest (HTTP + auth) and/or built-in VNC → any AI controls it via MCP or VNC.
2. **Minimal setup**: Windows Sandbox (+ Windows-MCP bootstrapped by a LogonCommand) — disposable;
   accept that anything installed and any login is redone each session.

## Decision

Nexo Box uses architecture 1: `dockur/windows` + Windows-MCP. The deciding factors:

- **Windows compatibility is guaranteed.** A real Windows 11 guest runs any Windows software without
  the Wine/Proton uncertainty of Linux-based options.
- **State persists.** dockur/windows keeps a persistent disk, so anything installed (and any login)
  survives reboots. Windows Sandbox is ephemeral and would reset every session.
- **AI access is built in and flexible.** noVNC (:8006), raw VNC, and RDP (:3389) ship out of the box,
  and Windows-MCP adds programmatic tools (screenshot + mouse/keyboard + PowerShell) over authenticated
  HTTP inside the guest. For apps with no accessibility tree, Windows-MCP drives them by vision + coordinates.
- **The cost is acceptable.** The trade-off is weight (a ~8 GB image, a few GB of RAM, software DX11/WARP
  because there is no GPU), but that is fine for lightweight desktop workloads.

In short: Windows-MCP is the AI-access layer placed inside the box, and dockur/windows is the box.
Together they provide a disposable, persistent, fully AI-controllable Windows environment.
