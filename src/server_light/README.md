# TealKit Server Light 🚀

**TealKit Server Light** is a lightweight edition of `tealkit_server` targeting ARM Linux single-board computers (Raspberry Pi, BeagleBone, etc.) and low-resource environments with **≥512 MB RAM**.

It reuses the full `tealkit_server` REST API codebase but uses **SQLite** instead of DuckDB and disables resource-heavy features via `ServerFeatureFlags.light`.

---

## ✅ Supported Features

| Feature | Light Mode |
|---------|-----------|
| Task/agent CRUD (`/api/v1/tasks`) | ✅ Full |
| Agent execution with LLM proxies | ✅ Full |
| LLM Settings (OpenAI, Gemini, Claude, Mistral, Ollama, OpenAI-compatible) | ✅ Full |
| Embedded/local models (llama.cpp / GGUF) | ❌ Disabled |
| Model download / GPU queries | ❌ Disabled |
| External MCP servers (SSE/HTTP) | ✅ Full |
| Internal MCP tools: SSH, Weather, IMAP, Web Search, Gmail, Google Calendar/Drive, Home Assistant, JS/Python bridges, Toolbox | ✅ Full |
| Internal MCP tools: Excel, Document, PDF, Chart, Mermaid, File | ❌ Filtered in UI |
| Website/Document indexing (semantic search) | ❌ Disabled |
| Cron scheduler | ❌ Disabled |
| DuckDB engine | ❌ (SQLite used instead) |

### UI Compatibility

The TealKit desktop/mobile app connects to server_light via the same REST API. The app automatically detects light mode from the `/health` endpoint and:

- Hides **"Embedded"** from the LLM provider dropdown
- Filters out unsupported MCP tools (Excel, Document, PDF, Chart, Website Search) from the workflow editor
- Skips embedded-model download/file-list endpoints

---

## 🛠️ Build & Deploy

### Prerequisites

- **On the ARM device:** Dart SDK ≥ 3.8.0 and `libsqlite3-dev`
- **On the build machine:** Bash, Docker (for cross-compilation)

### Option 1: Cross-compile from x86_64 (Docker)

Build a native ARM binary from your desktop/laptop using Docker:

```bash
# For 64-bit ARM (Raspberry Pi 4/5, ARM64 SBCs):
bash server_light/scripts/build_docker_arm.sh linux/arm64

# For 32-bit ARMv7 (BeagleBone, older Pi):
# NOTE: The dart:stable Docker image does NOT ship a 32-bit ARM variant.
# Build natively on the device instead (Option 3).
```

The binary is written to `server_light/dist/tealkit-server-light`. Copy it to the target device:

```bash
scp server_light/dist/tealkit-server-light user@arm-device:/opt/tealkit/
```

> **Limitation:** Docker cross-compilation only works for `linux/arm64`. For 32-bit ARMv7 devices, build natively (Option 3).

### Option 2: Package source for native build on ARM

Creates a minimal tarball (~1 MB) with only the required source files and stub packages — no binaries, no Flutter SDK:

```bash
bash server_light/scripts/package_light.sh
# → dist/tealkit_light_deploy.tar.gz

# Copy to ARM device
scp dist/tealkit_light_deploy.tar.gz root@arm-device:/opt/tealkit/
```

**Prerequisites on the ARM device:**
- Dart SDK ≥ 3.8.0 — install with `bash server_light/scripts/install_dart_arm.sh`
- `libsqlite3-dev` — install with `apt-get install -y libsqlite3-dev`

On the ARM device:

```bash
cd /opt/tealkit
tar xzf tealkit_light_deploy.tar.gz
bash build_and_run.sh
```

This resolves dependencies (`dart pub get`), compiles a native binary (`dart compile exe`), and starts the server — all on the target device.

For persistent deployment, install as a systemd service:

```bash
bash server_light/scripts/install_service.sh
```

### Option 3: Build directly on the ARM device

If the project source is already on the device:

```bash
# Install Dart (if not already present)
bash server_light/scripts/install_dart_arm.sh

# Build and run
bash scripts/build_arm_light.sh
```

---

## 🚀 Running

```bash
# Default: binds to localhost:7771, data in ~/.tealkit-server
./tealkit-server-light

# Custom port and host (accessible from network)
TEALKIT_HOST=0.0.0.0 TEALKIT_PORT=8080 ./tealkit-server-light

# Custom data directory
TEALKIT_DATA_DIR=/opt/tealkit/data ./tealkit-server-light
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TEALKIT_HOST` | `localhost` | Bind address (`0.0.0.0` for network access) |
| `TEALKIT_PORT` | `7771` | HTTP listen port |
| `TEALKIT_DATA_DIR` | `~/.tealkit-server` | Data directory (DB, config, keys) |

### Health Check

```bash
curl http://localhost:7771/api/v1/health
# → {"status":"ok","mode":"light","engine":"sqlite"}
```

### Firewall (Linux)

```bash
# Allow port 7771
iptables -A INPUT -p tcp --dport 7771 -j ACCEPT
# or
ufw allow 7771
```

---

## 🏗️ Architecture

```
server_light/
├── bin/server_light.dart       # Entry point — SQLite + light flags
├── pubspec.yaml                # Depends on tealkit_server + sqlite3
│                                # dependency_overrides → stub dart_duckdb + llamadart
├── scripts/
│   ├── build.sh                # Native Dart compile & run
│   ├── build_docker_arm.sh     # Docker cross-compile (ARM64)
│   ├── package_light.sh        # Minimal deployment tarball
│   ├── install_dart_arm.sh     # Install Dart SDK on ARM Linux
│   ├── install_service.sh      # Install systemd service for auto-start
│   ├── install_uv_check_node.sh # Install uv, Python, Node.js deps
│   └── run_light_arm.sh        # Convenience run script for ARM
└── dist/                       # Build output directory
```

### How it works

`server_light` depends on `tealkit_server` via path (`../server`) and reuses its entire REST API. To avoid pulling in heavy/Flutter-dependent transitive dependencies:

- **`dependency_overrides`** swap `dart_duckdb` → `dart_duckdb_light` (stub without Flutter SDK) and `llamadart` → `llamadart_stub` (stub without native build hooks). See [`server_light/pubspec.yaml`](pubspec.yaml).
- **`ServerFeatureFlags.light`** disables embedded models, indexing, PDF/chart/document/excel/file tools, semantic search, and the cron scheduler.
- **`ServerSqliteAdapter`** replaces DuckDB with SQLite — same schema, zero external dependencies beyond `libsqlite3`.
- The server code was refactored so `server_runner.dart` no longer directly imports `server_duckdb_adapter.dart` or `server_embedded_llm_adapter.dart`, using a factory pattern (`defaultDbFactory`) and dynamic dispatch (`embeddedLlmInstance`) instead.

### System Dependencies (ARM device)

```bash
apt-get install -y libsqlite3-0 libsqlite3-dev
```
