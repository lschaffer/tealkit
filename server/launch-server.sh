#!/usr/bin/env bash
# TealKit Server - start / stop / restart / status
# Usage: bash launch.sh [start|stop|restart|status|logs]
#        Default action is "start"
#
# Run this from any directory - it always operates on ~/tealkit-server/

set -euo pipefail

INSTALL_DIR="$HOME/tealkit-server"
ACTION="${1:-start}"

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
  fail "TealKit Server not installed. Run install-server.sh first."
fi

cd "$INSTALL_DIR"

case "$ACTION" in
  start)
    echo "  Starting TealKit Server..."
    docker compose up -d
    ok "Container started"

    echo "  Waiting for server to be ready..."
    HEALTHY=0
    for i in $(seq 1 15); do
      if curl -sf "http://localhost:7771/health" &>/dev/null; then
        ok "Server is healthy at http://localhost:7771"
        HEALTHY=1
        break
      fi
      sleep 2
    done
    if [ "$HEALTHY" -eq 0 ]; then
      warn "Server did not respond within 30s. Check logs: docker logs tealkit_server"
    fi
    ;;

  stop)
    echo "  Stopping TealKit Server..."
    docker compose down
    ok "Container stopped"
    ;;

  restart)
    echo "  Restarting TealKit Server..."
    docker compose down
    docker compose up -d
    ok "Container restarted"
    ;;

  status)
    docker compose ps
    ;;

  logs)
    docker logs -f tealkit_server
    ;;

  *)
    echo "Usage: bash launch.sh [start|stop|restart|status|logs]"
    exit 1
    ;;
esac
