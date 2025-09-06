#!/bin/bash
# Deployment-Script für Edge Monitoring Daemon

set -e

echo "🚀 Deploying Edge Monitoring Daemon..."

# 1. Verzeichnis erstellen
echo "📁 Creating directories..."
sudo mkdir -p /opt/monitoring
sudo mkdir -p /opt/python_scripts

# 2. Scripts kopieren
echo "📋 Copying scripts..."
sudo cp edge_daemon.py /opt/monitoring/edge_daemon.py
sudo cp status_daemon.py /opt/monitoring/status_daemon.py
sudo cp config.yaml /opt/monitoring/config.yaml

# 3. Berechtigungen setzen
sudo chmod +x /opt/monitoring/edge_daemon.py
sudo chmod +x /opt/monitoring/status_daemon.py
sudo chown -R monitoring:monitoring /opt/monitoring

# 4. Alten IPMI Timer stoppen (falls vorhanden)
echo "🛑 Stopping old IPMI timer..."
sudo systemctl stop get_ipmi_data.timer 2>/dev/null || echo "No old timer found"
sudo systemctl disable get_ipmi_data.timer 2>/dev/null || echo "No old timer to disable"

# 5. Neuen Service installieren
echo "⚙️  Installing systemd service..."
sudo cp edge-monitoring.service /etc/systemd/system/
sudo systemctl daemon-reload

# 6. Service starten
echo "🚀 Starting service..."
sudo systemctl enable edge-monitoring.service
sudo systemctl start edge-monitoring.service

# 7. Status anzeigen
echo "📊 Service Status:"
sudo systemctl status edge-monitoring.service --no-pager

echo ""
echo "✅ Deployment completed!"
echo ""
echo "💡 Useful commands:"
echo "   Status anzeigen:     python3 /opt/monitoring/status_daemon.py"
echo "   Logs anzeigen:       journalctl -u edge-monitoring.service -f"
echo "   Service stoppen:     sudo systemctl stop edge-monitoring.service"
echo "   Service starten:     sudo systemctl start edge-monitoring.service"
echo "   Service neustarten:  sudo systemctl restart edge-monitoring.service"
