#!/bin/bash
set -e

echo "🔄 Rolling back to systemd timer for IPMI..."

# 1. Daemon stoppen
echo "🛑 Stopping daemon..."
sudo systemctl stop edge-monitoring.service
sudo systemctl disable edge-monitoring.service

# 2. Alten IPMI Timer wiederherstellen (falls vorhanden)
echo "🔄 Restoring old timer..."
if [ -f "/etc/systemd/system/get_ipmi_data.timer" ]; then
    sudo systemctl enable --now get_ipmi_data.timer
    echo "✅ Old timer restored"
else
    echo "⚠️  No old timer found - you need to create it manually"
fi

# 3. Daemon-Dateien entfernen (optional)
read -p "🗑️  Remove daemon files? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo rm -rf /opt/monitoring
    sudo rm /etc/systemd/system/edge-monitoring.service
    sudo systemctl daemon-reload
    echo "✅ Daemon files removed"
fi

echo "✅ Rollback completed!"
