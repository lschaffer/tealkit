# TealKit Server Light 🚀

**TealKit Server Light** is a lightweight, low-footprint edition of `tealkit_server` specifically designed for **microcontrollers, Raspberry Pi (3/4/5), embedded ARM Linux single-board computers**, and low-resource environments with as little as **1GB RAM**.

---

## 🌐 Full TealKit UI Compatibility (Same REST API)

`server_light` implements the exact same `/api/v1/` REST API endpoints as full `tealkit_server`, allowing the TealKit UI app (Desktop, Web, Mobile) to connect seamlessly to TealKit Server Light.

### Supported Configuration Endpoints:
- **LLM Settings**: `GET /api/v1/settings/llm`, `PUT /api/v1/settings/llm`
- **External Tools & MCP**: `GET /api/v1/settings/external-tools`, `PUT /api/v1/settings/external-tools`
- **Preferences**: `GET /api/v1/settings/preferences`, `PUT /api/v1/settings/preferences`
- **MCP Server Controls**: `GET /api/v1/mcp/servers`, `POST /api/v1/mcp/servers/<id>/start`, `POST /api/v1/mcp/servers/<id>/stop`
- **Health Probes**: `GET /health`, `GET /status`

---

## 🔌 MCP Configuration Methods

### Method 1: Via TealKit UI App (REST API)
Navigate to **Settings -> External Tools & MCP** in the TealKit UI, enter server URLs or local commands, and click **Save**. The server automatically saves the configuration into SQLite and hot-loads the MCP registry.

### Method 2: Via Direct JSON API call / Config Store
Send a `PUT /api/v1/settings/external-tools` payload:

```json
{
  "selected_servers": [
    {
      "id": "remote_cloud_mcp",
      "name": "Cloud MCP Endpoint",
      "transportType": "https",
      "url": "https://mcp.example.com/sse",
      "enabled": true
    },
    {
      "id": "local_gpio_python",
      "name": "Local GPIO Python Tool (User Risk)",
      "transportType": "python",
      "command": "python3",
      "args": ["/opt/mcp/gpio.py"],
      "enabled": true
    }
  ]
}
```

---

## 🛠️ Building & Cross-Compiling

### 1. Build for ARM Linux from Windows / WSL2 / macOS (Recommended Docker Method)

Run the included Docker script to cross-compile an ARM64 binary:

```bash
bash scripts/build_docker_arm.sh linux/arm64
```

*Or run directly via PowerShell on Windows:*
```powershell
docker run --rm --platform linux/arm64 `
  -v ${PWD}:/app `
  -w /app `
  dart:stable `
  sh -c "dart pub get && dart compile exe bin/server_light.dart -o dist/server_light_arm"
```

### 2. Native Compilation directly on Raspberry Pi

If building directly on target ARM hardware (e.g. Raspberry Pi running Raspberry Pi OS / Ubuntu ARM):

```bash
bash scripts/build.sh
```

---

## 🚀 Running TealKit Server Light

```bash
# Run standalone binary
./dist/tealkit-server-light

# Environment overrides:
PORT=7771 TEALKIT_DB_PATH=tealkit.db ./dist/tealkit-server-light
```
