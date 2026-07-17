# Full access to a box

A Nexo Box is a real Windows machine that you (and any AI agent) get **complete control** over —
see the screen, drive the mouse and keyboard, run arbitrary PowerShell, install software, edit the
registry, and transfer files. The guest runs with a local admin account and UAC disabled, so there
is nothing to elevate: anything an administrator can do, the API and the remote session can do too.

There are three access surfaces, all bound to `127.0.0.1` (this PC only):

| Surface | Address | Best for |
| --- | --- | --- |
| **Screen (noVNC)** | `http://localhost:8006` | Watching and using the box by hand in a browser |
| **RDP** | `localhost:3389` (user `Docker`, password `admin`) | A full remote desktop session |
| **Windows-MCP** | `http://localhost:8000/mcp` | AI agents controlling the box programmatically |

> Ports shown are for the base box. Each managed instance gets its own: noVNC `810N`, RDP `820N`,
> MCP `830N` (N = the instance slot). NexoGate shows and copies them per instance.

## 1. AI control (Windows-MCP)

The box runs a [Windows-MCP](https://github.com/CursorTouch/Windows-MCP) server. Over authenticated
HTTP it exposes tools an AI uses to fully operate Windows:

- **Screenshot** — capture the screen (dxcam/GDI; works without a GPU).
- **Click / Type / Scroll / Move / Shortcut / Drag** — synthetic mouse and keyboard (Win32 input).
- **PowerShell** — run any command or script in the box (this is the "do anything" tool).
- **App / Process / Clipboard / FileSystem / Registry / Snapshot** — launch apps, inspect processes,
  read/write the clipboard and files, edit the registry, read the UI tree.

### Get the endpoint and key

- **Base box**: run `status.bat` — it prints the URL (`http://localhost:8000/mcp`) and the
  `MCP_AUTH_KEY` (also stored in `.env`).
- **Any managed instance**: open NexoGate (`nexo.bat`) and click the key icon on the instance row —
  it copies `http://localhost:830N/mcp` and the instance's Bearer key.

### Connect an AI

**Claude Code** — one click:

```
connect-claude.bat
```

**Any other MCP client** — generic HTTP config:

```json
{
  "mcpServers": {
    "nexo-box": {
      "type": "http",
      "url": "http://localhost:8000/mcp",
      "headers": { "Authorization": "Bearer <MCP_AUTH_KEY>" }
    }
  }
}
```

### Drive it directly (no MCP client)

The endpoint is a standard streamable-HTTP MCP server. Any script can speak to it: `initialize`,
send `notifications/initialized`, then `tools/call`. Minimal Python:

```python
import json, urllib.request
URL = "http://localhost:8000/mcp"
HDR = {"Authorization": "Bearer <KEY>", "Content-Type": "application/json",
       "Accept": "application/json, text/event-stream"}

def post(body, sid=None):
    h = dict(HDR)
    if sid: h["Mcp-Session-Id"] = sid
    r = urllib.request.urlopen(urllib.request.Request(URL, data=json.dumps(body).encode(), headers=h))
    data = None
    for line in r.read().decode().splitlines():
        if line.startswith("data:"): data = json.loads(line[5:].strip())
    return r.headers.get("Mcp-Session-Id"), data

sid, _ = post({"jsonrpc":"2.0","id":1,"method":"initialize",
               "params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}})
post({"jsonrpc":"2.0","method":"notifications/initialized"}, sid)

# run any PowerShell in the box:
_, out = post({"jsonrpc":"2.0","id":2,"method":"tools/call",
               "params":{"name":"PowerShell","arguments":{"command":"Get-Date; whoami"}}}, sid)
print(out)
```

> The endpoint has **no trailing slash** (`/mcp`, not `/mcp/`) — the server 307-redirects the slash
> form and some clients drop the auth header on redirect.

### Notes for driving apps

For normal Windows UI, the accessibility tree (`Snapshot`) is enough. For apps that don't expose one
(many games, DirectX/GPU apps, custom canvases), operate **by vision + coordinates**: `Screenshot`
to see, then `Click`/`Type` at pixel positions.

## 2. Manual control (noVNC / RDP)

- **noVNC** (`http://localhost:8006`): the box's live screen in your browser — click and type as if
  you were sitting at it. This mirrors the same session the MCP Screenshot sees.
- **RDP** (`localhost:3389`, `Docker` / `admin`): a full remote desktop. Note: connecting over RDP
  moves the session off the console, which stops MCP Screenshot until you log back in through noVNC.
  Prefer noVNC when an AI is also using the box.

## 3. Modifying the box

The box is a normal, persistent Windows install — change it however you like:

- **Install software**: use the screen (download and run installers) or have the AI do it via the
  PowerShell tool (`winget`, direct downloads, silent installers). Everything persists on the box's
  disk (`storage/`), so it survives reboots.
- **Send files in**: NexoGate → **Transfer** tab → upload from your PC. Files land in the box's
  `Shared` folder (`\\host.lan\Data` / the "Shared" desktop shortcut). Download them back the same way.
- **Provision automatically**: edit `oem/setup.ps1` to preinstall your own tools on every fresh box
  (it runs at each logon). Set `STEAM_APP_ID` in `.env` if you want a specific Steam app installed.
- **Experiment freely**: clone the base in NexoGate, break things in the clone, and delete it when
  done — the base template stays untouched.

## Security

Everything is bound to `127.0.0.1`, so nothing is reachable from the network by default. The MCP key
is the only credential gating AI access; keep it private. To expose the box on your LAN, change the
port bindings in `compose.yml` (`127.0.0.1:` → `0.0.0.0:`) and change the RDP password first.
