# TealKit Server — Docker Setup Guide

Run TealKit as a headless server on any always-on Linux machine (Raspberry Pi, NVIDIA Jetson Nano, Mac Mini, home-lab VM, VPS) so that your scheduled agents run 24/7 and your mobile/desktop app connects remotely.

---

## Prerequisites

| Requirement | Minimum version | Notes |
|---|---|---|
| **Docker Engine** | **24.0** | Compose V2 (`docker compose`) is built in from Docker 23+. Docker Desktop 4.x on macOS/Windows is fine. |
| **Docker Compose** | **2.20** | Bundled with Docker Engine 24. Check with `docker compose version`. |
| **OS / architecture** | Linux x86-64 (amd64) | ARM64 (Raspberry Pi 4/5, Jetson Nano) support coming with next release. |
| **RAM** | 256 MB free | The server binary is lean; add more if you run large Ollama models alongside it. |
| **Disk** | 500 MB | For the image layers + your data volume. |
| **Open port** | 7771 (TCP) | Reachable from the app. Open this port in your firewall / router NAT if accessing from outside your LAN. |

---

## Installation

Download two files from the [releases page](https://github.com/lschaffer/tealkit-privacy/releases):

- `tealkit_server_<version>.tar.gz` — the Docker image archive
- `install-server.sh` — the one-command setup script

No build toolchain or source code needed — just Docker.

The image is a security-hardened, distroless container with zero CVEs. It ships only the AOT-compiled server binary and the DuckDB library — no Dart runtime, no shell, no package manager.

### Quick install (one command)

```bash
bash install-server.sh tealkit_server_1.1.7.tar.gz
```

The script:
1. Verifies Docker 24+ and Compose 2.20+ are installed
2. Loads the image from the archive
3. Generates a random API key
4. Writes `docker-compose.yml` and `.env` into `~/tealkit-server/`
5. Starts the container and confirms the health endpoint is responding
6. Prints the server URL and API key to enter in the app

### Manual steps

```bash
# Linux / macOS
gunzip -c tealkit_server_1.1.7.tar.gz | docker load

# or
docker load < tealkit_server_1.1.7.tar.gz
```

#### 2. Run with a single command

```bash
docker run -d \
  --name tealkit_server \
  --restart unless-stopped \
  -p 7771:7771 \
  -v tealkit_data:/data \
  -e TEALKIT_API_KEY="YOUR_API_KEY" \
  ghcr.io/lschaffer/tealkit-server:latest
```

#### 3. Or use Docker Compose

Download the provided `docker-compose.yml` setup file (included in the release), place it in an empty folder and run:

```bash
docker compose up -d
```

**docker-compose.yml:**

```yaml
services:
  tealkit_server:
    image: ghcr.io/lschaffer/tealkit-server:latest
    container_name: tealkit_server
    restart: unless-stopped
    ports:
      - "7771:7771"
    volumes:
      - ./data:/data               # persistent data: DB, outputs, logs
    environment:
      TEALKIT_DATA_DIR: /data
      TEALKIT_PORT: "7771"
      TEALKIT_HOST: "0.0.0.0"
      TEALKIT_API_KEY: "replace-with-your-secret-key"
```

Start / stop:

```bash
docker compose -f server/docker-compose.yml up -d      # start in background
docker compose -f server/docker-compose.yml logs -f    # follow logs
docker compose -f server/docker-compose.yml down       # stop and remove container
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `TEALKIT_PORT` | `7771` | HTTP port the server listens on. |
| `TEALKIT_HOST` | `0.0.0.0` | Bind address. Use `0.0.0.0` to accept connections from outside the container. |
| `TEALKIT_DATA_DIR` | `/data` | Root data directory inside the container (DB, output files, logs). |
| `TEALKIT_API_KEY` | *(unset)* | Bearer token required on all non-`/health` endpoints. **Always set this** when the port is reachable from outside localhost. |

### Generating a strong API key

```bash
# Linux / macOS
openssl rand -hex 32

# PowerShell (Windows)
[System.Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Max 256 }))
```

The TealKit app generates a random key automatically on first launch in Server Mode Settings — you can copy it from there.

---

## Verifying the server is running

```bash
# Health check (no API key required)
curl http://<server-ip>:7771/health

# Expected response
{"status":"ok","version":"..."}
```

---

## Connecting from the TealKit app

1. Open **Settings → Server Mode**.
2. Toggle **Remote Server**.
3. Enter `http://<server-ip>:7771` in the **Server URL** field.
4. Paste your `TEALKIT_API_KEY` value in the **API Key** field.
5. Tap **Test Connection** — you should see a success message.

For HTTPS (recommended over the public internet) put a reverse proxy such as Nginx or Caddy in front of the container and update the URL to `https://`.

---

## Data persistence

All server data lives in the `/data` volume:

```
/data/
  db/        ← DuckDB database files (tasks, schedules, documents)
  output/    ← task output files written by agents
  logs/      ← server log files
```

The bind-mount in `docker-compose.yml` (`./data:/data`) keeps this data on the host even if the container is rebuilt or replaced.

**Backup:**

```bash
# Stop the container, archive the data directory, restart
docker compose stop
tar czf tealkit_backup_$(date +%Y%m%d).tar.gz data/
docker compose start
```

---

## Updating the server

Download the new `tealkit_server_<version>.tar.gz` from the releases page, then:

```bash
# Load the new image
gunzip -c tealkit_server_<version>.tar.gz | docker load

# Recreate the container with the new image
docker compose up -d --force-recreate
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `connection refused` on port 7771 | Container not running or wrong IP | Run `docker ps` to confirm; check logs with `docker logs tealkit_server`. |
| `401 Unauthorized` from app | API key mismatch | Ensure `TEALKIT_API_KEY` in compose matches the key entered in the app. |
| Tasks fail with "No LLM configured" | No LLM set up on the server side | Open the app, connect to the server, go to Settings → LLM and configure a provider. |
| Container exits immediately | Port already in use | Change the host port mapping, e.g. `7772:7771`. |
| Health check failing | Server still starting | Increase `start_period` in the healthcheck config or wait a few seconds after `docker compose up`. |
