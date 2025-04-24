#!/bin/bash
#
#  install_gateway_service.sh — Installer for DXSpider Gateway Node as a systemd service
#
#  Description:
#    This script installs and configures the DXSpider Gateway script (`gateway.pl`) as a
#    systemd service, allowing it to run automatically on boot and restart on failure.
#
#  Usage:
#    ./install_gateway_service.sh
#
#  Requirements:
#    - gateway.pl must be present at /root/volumenes/dxspider/nodo-2/local_cmd/gateway.pl
#    - Root privileges (will prompt for sudo).
#    - systemd-compatible system.
#
#  Actions:
#    - Makes gateway.pl executable
#    - Creates /etc/systemd/system/gateway.service
#    - Enables the service to start at boot
#    - Starts the service immediately
#
#  Monitoring:
#    journalctl -fu gateway.service
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250424 v0.4
#  License : GNU GPLv3
#

set -e

SCRIPT_DEST="/spider/local_cmd/gateway.pl"
SERVICE_FILE="/etc/systemd/system/gateway.service"

echo "==> Ensuring gateway.pl is executable..."
sudo chmod +x "$SCRIPT_DEST"

echo "==> Creating systemd service file..."
sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=DXSpider Gateway Node
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/perl $SCRIPT_DEST
WorkingDirectory=/spider/local_cmd
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=gateway-node
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Reloading systemd daemon..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

echo "==> Enabling gateway service..."
sudo systemctl enable gateway.service

echo "==> Starting gateway service..."
sudo systemctl start gateway.service

echo "Installation complete. Use 'journalctl -fu gateway.service' to monitor logs."
