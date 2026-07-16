# NexoGate — Instance Manager

Web dashboard (NEXO design) to **create, clone, delete, and monitor** box
instances (Windows + Steam + the game). The already-installed box is the
**base/template**; each instance is a copy of its disk, with its own ports and
AI key.

## How to open

Double-click **`nexo.bat`** (in the project root). It starts the local server
and opens the dashboard in your browser (`http://localhost:7099/`, or the next
free port). Close the console window to stop the server.

> Requires Docker running (the box installs everything). The base must exist
> (`storage/data.qcow2`) — it is the instance you already created and optimized.

## What you can do

- **Create / clone** — copies the base disk (Windows + Steam + game ready) and
  brings up a new instance with the RAM/cores you choose. Each one gets a unique
  MCP key.
- **Start / stop / restart** each instance.
- **Delete** — stops and removes the instance and its disk (the base is left untouched).
- **Monitor usage** — live CPU and RAM (docker stats) + actual disk (qcow2 thin).
- **Open the screen** of each instance (noVNC) and **copy the AI access** (MCP endpoint + key).
- **Data transfer** — copies files from one instance's `shared` folder to
  another (Transfer tab).

## Ports per instance

Bound to `127.0.0.1`. Instance in slot N:

| Service | Port |
| --- | --- |
| Screen (noVNC) | `810N` |
| RDP | `820N` |
| MCP (AI) | `830N` |

The dashboard itself runs on `7099` (or the next free port; the active URL is
written to `nexo/active.url`).

## Structure

```
nexo/
├── server.ps1          # backend: HttpListener + REST API (zero dependencies)
├── clone-instance.ps1  # worker: clones disk+metadata from the base, generates config, brings it up
├── active.url          # active URL (generated at startup; the .bat opens it)
└── www/                # frontend (NEXO design)
    ├── index.html
    ├── styles.css
    ├── app.js
    └── logo.png
instances/<name>/       # each instance: compose.yml, .env, storage/, shared/, oem/
```

## API (REST, local)

| Method | Route | Action |
| --- | --- | --- |
| GET | `/api/overview` | aggregate metrics + base/docker state |
| GET | `/api/instances` | list + live stats |
| POST | `/api/instances` | create/clone (`{name, ram, cpu, cpus, source}`) |
| POST | `/api/instances/{name}/start\|stop\|restart\|delete` | actions |
| POST | `/api/transfer` | copy data (`{from, to}`) between `shared` folders |

## Technical details

- **Correct cloning**: copies `data.qcow2` **plus the metadata**
  (`windows.ver/base/boot/vars/rom`) so dockur recognizes the disk as already
  installed (otherwise it would reinstall from scratch). `windows.mac` is
  skipped on purpose → each clone gets a unique MAC.
- **New MCP key per clone**: written to `shared/mcp.key`; the `setup.ps1` inside
  the guest reads the live key and restarts the MCP server with it.
- **Backend in pure PowerShell** (HttpListener) so it needs no Node/Python —
  the same zero-dependency philosophy as the rest of the project. `nexo.bat`
  self-elevates (the HttpListener needs privilege to bind).
