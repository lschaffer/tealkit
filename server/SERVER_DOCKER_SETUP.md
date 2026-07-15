# TealKit Server - Installation Guide

This document is intentionally focused on **server deployment only**.
It does **not** explain rebuilding Docker images from source.

---
 
 ## 💻 Hardware Requirements
 
 TealKit Server itself is extremely lightweight. The required system memory and acceleration depend entirely on whether you utilize cloud-based APIs or run local inference:
 
 | Requirement Level | Memory (RAM) | Recommended Hardware | Use Case |
 |---|---|---|---|
 | **Minimum** | **4 GB** | Raspberry Pi 4/5 (4GB), standard cloud VPS | Connecting to external API endpoints (Gemini, OpenAI, Anthropic) for agent execution. |
 | **Recommended** | **8 GB** | Raspberry Pi 5 (8GB), Mini PC, native Mac/PC | Standard configuration, ensuring fast DuckDB operations and concurrent task scheduling. |
 | **Local LLM Execution** | **8 GB+** | Raspberry Pi 5 (8GB) with **Hailo-8/Hailo-10** M.2 AI acceleration module (40 TOPS), NVIDIA Jetson Orin Nano, or Apple Silicon Mac | Running local models natively on the edge via Ollama or embedded GGUF runtimes. |
 
 ---

## Release Package Contents (only)

For GitHub release distribution, publish only:

1. `tealkit_server_<version>.tar.gz` (server Docker image archive)
2. `install-server.sh` (install helper script)
3. `SERVER_DOCKER_SETUP.md` (this file)

No Docker build files are required for end users.

---

## Download (Available now)

Use these direct links based on your CPU architecture:

### 🖥️ Linux x86-64 (Standard)
1. Server image archive: https://tealkit.dev/download/tealkit_server_deploy.tar.gz
2. Installer script: https://raw.githubusercontent.com/lschaffer/tealkit/master/install-server.sh

### 🍓 ARM64 (Raspberry Pi 5 / Apple Silicon M1-M4)
1. Server image archive: https://tealkit.dev/download/tealkit_server_deploy_arm64.tar.gz
2. Installer script: https://raw.githubusercontent.com/lschaffer/tealkit/master/install-server-arm64.sh

Then continue with quick install.

## Quick Install

Prerequisites:

1. Docker 24+ with Compose V2
2. Linux x86-64 or ARM64 host

Run the setup matching your hardware architecture:

### 🖥️ Linux x86-64 (Standard)
```bash
# 1) Download the installer from GitHub
curl -fsSLO https://raw.githubusercontent.com/lschaffer/tealkit/master/install-server.sh
chmod +x install-server.sh

# 2) Run it; the image archive is downloaded automatically from tealkit.dev
bash install-server.sh --api-key YOUR_SERVER_API_KEY
```

### 🍓 ARM64 (Raspberry Pi 5 / Apple Silicon M1-M4)
```bash
# 1) Download the installer from GitHub
curl -fsSLO https://raw.githubusercontent.com/lschaffer/tealkit/master/install-server-arm64.sh
chmod +x install-server-arm64.sh

# 2) Run it; the image archive is downloaded automatically from tealkit.dev
bash install-server-arm64.sh --api-key YOUR_SERVER_API_KEY
```

Optional: use a local archive instead of downloading it again.
```bash
# Standard
bash install-server.sh ./tealkit_server_<version>.tar.gz --api-key YOUR_SERVER_API_KEY

# ARM64
bash install-server-arm64.sh ./tealkit_server_<version>_arm64.tar.gz --api-key YOUR_SERVER_API_KEY
```

Health check:
```bash
curl http://localhost:7771/health
```

---

## Required/Optional Runtime Mappings

Typical runtime mounts:

1. Required: `/data`
2. Recommended: `/tealkit`
3. Recommended: `/tealkit/files`
4. Optional external docs (read-only): `/home/tealkit/upload`

If you use optional external document indexing, map host folder to:

```text
/home/tealkit/upload
```

Use absolute paths in app server mode, for example:

1. `/home/tealkit/upload`
2. `/home/tealkit/upload/doc`

---

## Option A: Local Network / Intranet (HTTP, no reverse proxy)

Best for: Raspberry Pi, NVIDIA Jetson, local Mac, NAS, or any edge device on a trusted LAN.
No certificates required — connect directly over HTTP on port 7771.

### docker-compose.yml (HTTP only)

```yaml
services:
  tealkit_server:
    image: tealkit_server:latest
    container_name: tealkit_server
    restart: unless-stopped
    ports:
      - "7771:7771"          # directly exposed on LAN
    environment:
      TEALKIT_API_KEY: ${TEALKIT_API_KEY}
      TEALKIT_DATA_DIR: /data
      TEALKIT_FILES_DIR: /tealkit/files
      TEALKIT_HOST: 0.0.0.0
      TEALKIT_PORT: '7771'
      TZ: Europe/Berlin
    volumes:
      - ./data:/data
      - ./tealkit:/tealkit
      - ./files:/tealkit/files
      - ./upload:/home/tealkit/upload:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "/usr/bin/wget", "-qO-", "http://localhost:7771/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
```

Start:

```bash
docker compose up -d
```

Health check:

```bash
curl http://<device-ip>:7771/health
```

App server URL in TealKit (use device LAN IP or hostname):

```text
http://192.168.x.x:7771
```

> **Security note:** Keep `TEALKIT_API_KEY` set even on a LAN.
> Do not expose port 7771 to the internet without a reverse proxy and TLS.

---

## Option B: Internet / Cloud (HTTPS Reverse Proxy)

Best for: cloud VPS, home server with a public domain, or any host exposed to the internet.
Place TealKit behind an HTTPS reverse proxy (nginx + Let's Encrypt).

### docker-compose.yml (nginx + tealkit_server)

```yaml
services:
  tealkit_server:
    image: tealkit_server:latest
    container_name: tealkit_server
    restart: unless-stopped
    expose:
      - "7771"
    environment:
      TEALKIT_API_KEY: ${TEALKIT_API_KEY}
      TEALKIT_DATA_DIR: /data
      TEALKIT_FILES_DIR: /tealkit/files
      TEALKIT_HOST: 0.0.0.0
      TEALKIT_PORT: '7771'
      TZ: Europe/Berlin
    volumes:
      - /apps/containers/vol/tealkit_server/data:/data
      - /apps/containers/vol/tealkit_server/tealkit:/tealkit
      - /apps/containers/vol/tealkit_server/files:/tealkit/files
      - /apps/containers/vol/tealkit_server/upload:/home/tealkit/upload:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "/usr/bin/wget", "-qO-", "http://localhost:7771/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    networks:
      - tealkit_net


  nginx:
    image: nginx:1.27-alpine
    container_name: tealkit_nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - tealkit_server
    networks:
      - tealkit_net

networks:
  tealkit_net:
    driver: bridge
```

### Matching nginx config example (`nginx/conf.d/default.conf`)

```nginx
server {
    listen 80;
    server_name your.domain.tld;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your.domain.tld;

    ssl_certificate /etc/letsencrypt/live/your.domain.tld/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your.domain.tld/privkey.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location /tealkitserver/ {
        proxy_pass http://tealkit_server:7771/tealkitserver/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

App server URL in TealKit:

```text
https://your.domain.tld/tealkitserver
```

---

## Notes

1. Keep `TEALKIT_API_KEY` set when exposed publicly.
2. Do not expose raw `7771` publicly if using reverse proxy.
3. Keep certificates auto-renewed (certbot).
