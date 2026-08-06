#!/usr/bin/env bash
# Register TealKit Server Light as a systemd service on ARM Linux.
# Usage: sudo bash install_service.sh
#
# After installation:
#   systemctl start tealkit-light
#   systemctl stop tealkit-light
#   systemctl status tealkit-light
#   journalctl -u tealkit-light -f

set -e

SERVICE_NAME="tealkit-light"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run as root. Usage: sudo bash install_service.sh"
  exit 1
fi

cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=TealKit Server Light
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/tealkit
ExecStart=/bin/bash /opt/tealkit/run_light_arm.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "Service installed. Status:"
systemctl status "$SERVICE_NAME" --no-pager --lines=5
