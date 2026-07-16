# Nexo Box

A one-click system that runs a real **Windows desktop inside a container** ([dockur/windows](https://github.com/dockur/windows))
to sign in to Steam and play **TBH: Task Bar Hero**, with **full access for any AI agent**
via [Windows-MCP](https://github.com/CursorTouch/Windows-MCP) (screenshot + mouse/keyboard + PowerShell)
and through a noVNC/RDP screen.

## Installation (any PC)

1. Copy **this entire folder** to the target PC.
2. Double-click **`install.bat`** and accept the administrator prompt.
3. If it asks to restart, accept — **after the reboot it reopens on its own and continues**.
4. At the end it opens `http://localhost:8006`: the box's Windows installs itself (20-40 min, hands-off).
5. When the desktop appears, the box installs Steam and the AI server automatically. Then you just:
   - open **Steam** and sign in to **your account** (regular Steam Guard, only the first time — the login is saved);
   - click the **"Install TBH"** shortcut on the box's desktop.

**Host requirements**: Windows 11, virtualization enabled in the BIOS (Intel VT-x / AMD SVM),
16 GB of RAM recommended, ~30 GB of free disk space, an internet connection.

> The game **requires an internet connection** even though it is single-player: chest drops are
> validated server-side. The box ships with networking enabled.

## Day-to-day

| File | What it does |
| --- | --- |
| `start.bat` | Starts the box (and Docker, if needed) and opens the screen in your browser |
| `stop.bat` | Shuts the box down safely |
| `status.bat` | Shows state, addresses, and the MCP key |
| `connect-claude.bat` | Connects Claude Code to the box (one click) |
| `slim.bat` | Slims down an already-installed box (thin disk + lower RAM/CPU) without reinstalling |

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

## Slimming down as much as possible (RAM, CPU, disk)

New installations already ship slim by default (**4 GB RAM, 2 cores, thin disk**).
For an **already-installed** box, run **`slim.bat`**: it converts the disk to `qcow2`
(thin) and applies the limits **without reinstalling** (it preserves Windows, the Steam login, and the game).

What each setting does:

- **Disk: `DISK_FMT=qcow2`** — the biggest win. The disk becomes *thin* and only takes up what it
  actually uses (~15 GB instead of the 64 GB pre-allocated). To shrink it as much as possible, once
  inside the box run `defrag C: /O` from an admin prompt and restart the box.
- **RAM: `BOX_RAM_SIZE=4G`** — a debloated Win10 plus Steam and the game use ~2 GB; 4G leaves headroom.
- **CPU: `BOX_CPU_CORES=2` + `BOX_CPUS=2.0`** — the box never uses more than 2 host cores.
- **Automatic debloat** (in `setup.ps1`, on every boot): disables telemetry (DiagTrack), the indexer
  (WSearch), SuperFetch (SysMain), and Defender's real-time protection (with Steam added as an exception).

### The manual step that saves the most CPU: FPS cap

Because the box has no GPU, DirectX runs in software (WARP) and CPU cost is roughly proportional to
FPS. The game tries to run at 120/144 FPS in a tiny 100px window, which is pure waste. **In the TBH
settings, enable the FPS cap and set it to 20-30** (and quality to minimum). That alone cuts most of
the CPU usage. Optional: in Steam, right-click TBH → Properties → Launch options → `-force-d3d11`.

### An even leaner base (optional)

For a new installation, leaving **no `.iso` in the folder** and setting `BOX_VERSION=win10x64-ltsc` in
`.env` uses **Windows 10 LTSC** — the cleanest Win10 available (no Store/Cortana/Xbox, still updatable,
supported until 2027; `win10x64-iot` runs until 2032). This is safer and lighter than manually stripping
components out of an ISO (over-stripping breaks Steam and the game — Media Foundation, d3dcompiler_47,
WMIC, and the Segoe fonts are all required).

## Connecting AI agents

**Claude Code**: run `connect-claude.bat`. Done.

**Any other MCP client** (generic HTTP config):

```json
{
  "mcpServers": {
    "tbh-box": {
      "type": "http",
      "url": "http://localhost:8000/mcp",
      "headers": { "Authorization": "Bearer <MCP_AUTH_KEY from .env>" }
    }
  }
}
```

**An AI without MCP support**: use the noVNC screen (`http://localhost:8006`) with any computer-use
stack (page screenshot + clicks via Playwright/CDP).

Inside the game and Steam the AI must operate **by vision and coordinates** (Screenshot → Click):
the accessibility tree (the `Snapshot` tool) cannot see DirectX games.

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

Changed `.env`? Run `install.bat` again (it re-propagates the key and recreates the container; the disk
in `storage/` is preserved). Changing `MCP_AUTH_KEY` works without reinstalling the box: the new key
travels through the `shared/` folder and the MCP server inside the box restarts itself on the box's next logon/boot.

## Project structure

```
box/
├── install.bat          # one-click host installer (idempotent, resumes after reboot)
├── scripts/install.ps1  # installer logic (WSL2 → Docker Desktop → .env → compose up)
├── compose.yml          # the box itself (dockur/windows)
├── oem/                 # runs INSIDE the guest, automatically at the end of Windows setup
│   ├── install.bat      #   firewall + schedules setup on each logon
│   ├── setup.ps1        #   Steam + uv + Windows-MCP + shortcuts + power (idempotent)
│   └── mcp.key          #   MCP key frozen at install time (generated by the installer)
├── storage/             # the box's Windows disk (persistent; do not commit)
├── shared/              # live host ↔ box folder ("Shared" on the desktop; carries the current mcp.key)
├── start/stop/status.bat, connect-claude.bat
└── docs/architecture.md  # research that led to this architecture
```

## Security and warnings

- All ports are bound to `127.0.0.1` — **nothing is exposed on the network**. To reach the box from
  another PC on the local network, replace `127.0.0.1:` with `0.0.0.0:` in `compose.yml` (the MCP key
  then becomes your only protection; consider changing the RDP password too).
- The Windows image downloaded by dockur/windows comes **without activation** — use your own license
  to activate it.
- **ToS/ban risk**: TBH has server-side validation and real-money items on the Steam Market.
  An AI *playing for you* (automated farming) may violate the Steam and game terms and put your
  account at risk. Use AI access responsibly (assistance, reading the screen, navigation).
- The Steam login is saved **inside the box's disk** (`storage/`). Do not share that folder.

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
- **Performance**: the guest renders DirectX in software (WARP). For this game (a ~100 px window) that
  is enough; close other heavy programs if it stutters.

## Built on

- [dockur/windows](https://github.com/dockur/windows) — runs Windows inside a container (MIT). The
  unattended-answer files in `assets/` come from this project.
- [CursorTouch/Windows-MCP](https://github.com/CursorTouch/Windows-MCP) — the MCP server that gives
  AI agents screenshot + keyboard/mouse control of the guest (MIT).
