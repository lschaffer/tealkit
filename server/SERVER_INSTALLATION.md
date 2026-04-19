# TealKit Server - Installation Guide

This document is intentionally focused on **server deployment only**.
It does **not** explain rebuilding Docker images from source.

---

## Release Package Contents (only)

For GitHub release distribution, publish only:

1. `tealkit_server_<version>.tar.gz` (server Docker image archive)
2. `install-server.sh` (install helper script)
3. `SERVER_INSTALLATION.md` (this file)

No Docker build files are required for end users.

---

## Quick Install

Prerequisites:

1. Docker 24+ with Compose V2
2. Linux x86-64 or ARM64 host

Install:

```bash
# 1) Load image from release archive
docker load < tealkit_server_<version>.tar.gz

# 2) Run installer (creates runtime compose and starts server)
bash install-server.sh tealkit_server_<version>.tar.gz
```

Health check:

```bash
curl http://localhost:7771/tealkitserver/health
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

## Secure Internet Exposure (HTTPS Proxy)

If server should be reachable from the internet, place TealKit behind an HTTPS reverse proxy.

### Small docker-compose.yml example (nginx + tealkit_server)

```yaml
services:
  tealkit_server:
    image: tealkit_server:prod-full
    container_name: tealkit_server
    restart: unless-stopped
    expose:
      - "7771"
    environment:
      - TZ=UTC
      - TEALKIT_API_KEY=change_me
    volumes:
      - /apps/containers/vol/tealkit_server/data:/data
      - /apps/containers/vol/tealkit_server/tealkit:/tealkit
      - /apps/containers/vol/tealkit_server/files:/tealkit/files
      - /apps/containers/vol/tealkit_server/upload:/home/tealkit/upload:ro
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
