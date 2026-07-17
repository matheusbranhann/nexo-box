# Nexo Box

A one-click system that runs a real, disposable **Windows desktop**, **fully controllable by any AI
agent** via [Windows-MCP](https://github.com/CursorTouch/Windows-MCP) (screenshot + mouse/keyboard +
PowerShell) and through a screen (noVNC/RDP or VNC). It ships with **NexoGate**, a local web dashboard
to create, clone, monitor, and delete boxes.

The installer picks an engine automatically based on the host:

- **Windows 11** -> the box runs **inside a container** ([dockur/windows](https://github.com/dockur/windows),
  KVM via WSL2 nested virtualization).
- **Windows 10** -> the box runs on **native QEMU with the Windows Hypervisor Platform (WHPX)**, since
  dockur/windows requires Windows 11 (Windows 10 cannot expose `/dev/kvm` to containers). No Docker or
  WSL needed. A local Windows `.iso` next to `install.bat` is required on this engine.

## Installation (any PC)

1. Copy **this entire folder** to the target PC.
2. Double-click **`install.bat`** and accept the administrator prompt.
3. If it asks to restart, accept — **after the reboot it reopens on its own and continues**.
4. At the end it opens `http://localhost:8006`: the box's Windows installs itself (20-40 min, hands-off).
5. When the desktop appears, the box provisions itself automatically: it installs the Windows-MCP
   server (AI access) and whatever else `oem/setup.ps1` defines. From there, connect an AI agent, use
   the box through the browser screen, and install any software you need inside it.

**Host requirements**: Windows 10 or 11, virtualization enabled in the BIOS (Intel VT-x / AMD SVM),
16 GB of RAM recommended, ~30 GB of free disk space, an internet connection. On **Windows 10** you also
need a Windows `.iso` in this folder (the QEMU engine installs the guest from it) and the installer
enables the "Windows Hypervisor Platform" feature (one reboot; it resumes on its own).

## Day-to-day

| File | What it does |
| --- | --- |
| `start.bat` | Starts the box (and Docker, if needed) and opens the screen in your browser |
| `stop.bat` | Shuts the box down safely |
| `status.bat` | Shows state, addresses, and the MCP key |
| `connect-claude.bat` | Connects Claude Code to the box (one click) |
| `slim.bat` | Slims down an already-installed box (thin disk + lower RAM/CPU) without reinstalling |
| `nexo.bat` | Opens the NexoGate dashboard (create/clone/monitor/delete boxes) |

## Access (this PC only, by default)

| Service | Address | Purpose |
| --- | --- | --- |
| Browser screen (noVNC) | `http://localhost:8006` | View and use the box; visual computer-use agents |
| RDP | `localhost:3389` (user `Docker`, password `admin`) | Full remote session (see the warning below) |
| **Windows-MCP** | `http://localhost:8000/mcp` | AI controls the box (19 tools: Screenshot, Click, Type, PowerShell...) |

The MCP authentication key is stored in `.env` (`MCP_AUTH_KEY`); `status.bat` prints it.

> **RDP vs. screen capture**: connecting over RDP takes the session away from the "console" that
> noVNC mirrors. When you disconnect RDP, the session is left without a display and the
> **MCP Screenshot stops working** until you log in again through noVNC (or restart the box).
> Prefer noVNC for day-to-day use.

## Windows 10 (QEMU engine)

On a Windows 10 host the box runs on native QEMU (legacy BIOS + AHCI + e1000, so no extra drivers are
needed) accelerated by WHPX. Everything else — NexoGate, cloning, Windows-MCP — works the same. What
differs:

- **A local Windows `.iso` is required** next to `install.bat`; QEMU installs the guest from it hands-off
  (20–40 min) the first time. The result is the base template (`storage\base.qcow2`).
- **Screen is VNC** (not noVNC): the base is at `127.0.0.1:5900`, instance N at `127.0.0.1:590N`. Use any
  VNC viewer. **RDP** (`127.0.0.1:3389` base, `+N` per instance; user `Docker` / password `admin`) and
  **Windows-MCP** (`127.0.0.1:8000` base, `+N` per instance) work as usual.
- File transfer via NexoGate's Transfer tab is Docker-engine only for now; on Windows 10 move files
  through RDP or the MCP PowerShell tool.

## NexoGate — managing many boxes

Run `nexo.bat` to open a local dashboard that turns the installed box into a **base/template** and
lets you spin up more from it. Each new box is a copy of the base disk with its own ports and its own
AI key. See [`nexo/README.md`](nexo/README.md) for details. You can:

- **Create / clone** a box from the base (or from another box), with the RAM/cores you choose.
- **Start / stop / restart / delete** boxes.
- **Monitor usage** live (CPU + RAM from `docker stats`, real disk size from the thin qcow2).
- **Open the screen** (noVNC) and **copy the AI endpoint** (MCP URL + key) per box.
- **Transfer data** between the `shared` folders of two boxes.

## Slimming down as much as possible (RAM, CPU, disk)

New installations already ship slim by default (**4 GB RAM, 2 cores, thin disk**).
For an **already-installed** box, run **`slim.bat`**: it converts the disk to `qcow2` (thin) and
applies the limits **without reinstalling** (it preserves Windows and everything installed in it).

What each setting does:

- **Disk: `DISK_FMT=qcow2`** — the biggest win. The disk becomes *thin* and only takes up what it
  actually uses (~15 GB instead of the 64 GB pre-allocated). To shrink it as much as possible, once
  inside the box run `defrag C: /O` from an admin prompt and restart the box.
- **RAM: `BOX_RAM_SIZE=4G`** — a debloated Windows idles around ~2 GB; 4G leaves headroom.
- **CPU: `BOX_CPU_CORES=2` + `BOX_CPUS=2.0`** — the box never uses more than 2 host cores.
- **Automatic debloat** (in `oem/setup.ps1`, on every boot): disables telemetry (DiagTrack), the
  indexer (WSearch), SuperFetch (SysMain), and Defender's real-time protection.

### An even leaner base (optional)

For a new installation, leaving **no `.iso` in the folder** and setting `BOX_VERSION=win10x64-ltsc` in
`.env` uses **Windows 10 LTSC** — the cleanest Win10 available (no Store/Cortana/Xbox, still updatable,
supported until 2027; `win10x64-iot` runs until 2032). This is safer and lighter than manually stripping
components out of an ISO (over-stripping breaks common runtime dependencies — Media Foundation,
d3dcompiler_47, WMIC, and the Segoe fonts are all needed by many apps).

## Connecting AI agents

For a complete guide to controlling and modifying a box (MCP tools, PowerShell, noVNC/RDP, file transfer), see [docs/access.md](docs/access.md).

**Claude Code**: run `connect-claude.bat`. Done.

**Any other MCP client** (generic HTTP config):

```json
{
  "mcpServers": {
    "nexo-box": {
      "type": "http",
      "url": "http://localhost:8000/mcp",
      "headers": { "Authorization": "Bearer <MCP_AUTH_KEY from .env>" }
    }
  }
}
```

**An AI without MCP support**: use the noVNC screen (`http://localhost:8006`) with any computer-use
stack (page screenshot + clicks via Playwright/CDP).

For apps that don't expose an accessibility tree (many games and DirectX/GPU apps), the AI should
operate **by vision and coordinates** (Screenshot → Click) rather than the `Snapshot` tool.

## Configuration

Everything lives in `.env` (created by the installer):

- `BOX_VERSION=win10x64-ltsc` — Win10 LTSC (leanest). Others: `win10x64-iot`, `11l`, `11`, `10`.
  **Ignored if an `.iso` is present in the folder** (the box uses the local ISO).
- `BOX_RAM_SIZE=4G`, `BOX_CPU_CORES=2` — guest resources.
- `BOX_CPUS=2.0` — hard host CPU cap (the box never exceeds it).
- `BOX_DISK_SIZE=32G` — disk ceiling; with `qcow2` it is only a virtual limit and the disk uses what it needs.
- `BOX_DISK_FMT=qcow2` — thin disk (uses ~15 GB). `raw` = pre-allocated (faster, uses the full size).
- `BOX_USERNAME` / `BOX_PASSWORD` — the box's Windows account.
- `MCP_AUTH_KEY` — the key AI agents use; randomly generated during install.
- `STEAM_APP_ID` (optional) — a numeric Steam app id to auto-install; empty by default (a plain box).

Changed `.env`? Run `install.bat` again (it re-propagates the key and recreates the container; the disk
in `storage/` is preserved). Changing `MCP_AUTH_KEY` works without reinstalling the box: the new key
travels through the `shared/` folder and the MCP server inside the box restarts itself on the box's next logon/boot.

## Project structure

```
box/
├── install.bat          # one-click host installer (idempotent, resumes after reboot)
├── scripts/install.ps1  # installer logic (WSL2 -> Docker Desktop -> .env -> compose up)
├── compose.yml          # the box itself (dockur/windows)
├── oem/                 # runs INSIDE the guest, automatically at the end of Windows setup
│   ├── install.bat      #   firewall + schedules setup on each logon
│   ├── setup.ps1        #   AI server (Windows-MCP) + tools + power settings (idempotent)
│   ├── optimize.ps1     #   one-time aggressive Windows debloat/cleanup
│   └── mcp.key          #   MCP key frozen at install time (generated by the installer)
├── nexo/                # NexoGate dashboard (PowerShell HTTP server + web UI)
├── storage/             # the box's Windows disk (persistent; not committed)
├── shared/              # live host <-> box folder ("Shared" on the desktop; carries the current mcp.key)
├── start/stop/status.bat, connect-claude.bat, slim.bat, nexo.bat
└── docs/architecture.md # research that led to this architecture
```

## Security and warnings

- All ports are bound to `127.0.0.1` — **nothing is exposed on the network**. To reach the box from
  another PC on the local network, replace `127.0.0.1:` with `0.0.0.0:` in `compose.yml` (the MCP key
  then becomes your only protection; consider changing the RDP password too).
- The default box credentials are `Docker` / `admin` (change `BOX_PASSWORD` in `.env`).
- The Windows image downloaded by dockur/windows comes **without activation** — use your own license
  to activate it.
- Anything you sign into inside the box (accounts, tokens) is saved **inside the box's disk**
  (`storage/`). Do not share that folder.

## Troubleshooting

- **`/dev/kvm` does not exist / the box won't start**: three possible causes — (1) virtualization
  disabled in the BIOS; (2) `nestedVirtualization=false` in `%USERPROFILE%\.wslconfig` (the installer
  sets it to `true`; run `wsl --shutdown` after changing it); (3) recent WSL2 kernels (6.6+) don't load
  the KVM module on their own — `install.bat`/`start.bat` already run
  `wsl -d docker-desktop -u root -e sh -c "modprobe kvm_amd; modprobe kvm_intel"`, but if you bring the
  container up by hand, run that command first.
- **The installer stopped after a reboot**: run `install.bat` again — it resumes from the right point
  (the automatic resume uses an elevated scheduled task; if that doesn't launch, running it manually resolves it).
- **Docker Desktop shows a first-run wizard**: complete the wizard (you can skip the login) and run
  `install.bat` again.
- **MCP does not respond on 8000**: has the box finished installing? Run `status.bat` (it shows ONLINE/offline),
  check `C:\OEM\setup.log` inside the box, and log off/on in the box (setup runs on every logon).
- **MCP returns 401 (unauthorized)**: the key is out of sync — run `install.bat` (it re-propagates the
  key via `shared/`) and restart the box (`stop.bat` + `start.bat`).
- **MCP Screenshot is black or errors out**: someone used RDP and disconnected — connect through noVNC
  (`http://localhost:8006`) and log in to return the display to the session.
- **Wrong clock / "bad date" errors in apps**: the guest RTC can drift on a VM. `oem/setup.ps1` sets
  `RealTimeIsUniversal=1` and resyncs the time on every boot to keep it correct.
- **Performance**: the guest renders DirectX in software (WARP), since there is no GPU. That is fine
  for lightweight windows; close other heavy programs if it stutters.

## Built on

- [dockur/windows](https://github.com/dockur/windows) — runs Windows inside a container (MIT). The
  unattended-answer files in `assets/` come from this project.
- [CursorTouch/Windows-MCP](https://github.com/CursorTouch/Windows-MCP) — the MCP server that gives
  AI agents screenshot + keyboard/mouse control of the guest (MIT).
