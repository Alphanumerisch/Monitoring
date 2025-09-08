# Neue Scripts zum Edge Daemon hinzufügen

## 1. Script erstellen

Erstelle dein neues Monitoring-Script in `/opt/python_scripts/`:

```bash
sudo nano /opt/python_scripts/my_new_script.py
```

Wichtige Anforderungen für das Script:
- Muss mit Python 3 ausführbar sein
- Sollte Fehlerbehandlung haben
- Sollte Daten an Logstash senden (Port 10530)
- Exit-Code 0 bei Erfolg, != 0 bei Fehler

## 2. Script zur Konfiguration hinzufügen

Bearbeite die Daemon-Konfiguration:

```bash
sudo nano /opt/monitoring/config.yaml
```

Füge dein Script hinzu:

```yaml
scripts:
  # Bestehende Scripts...
  
  # Dein neues Script
  my_new_script:
    path: "/opt/python_scripts/my_new_script.py"
    interval: 300      # Ausführungsintervall in Sekunden
    args: []           # Optionale Argumente als Liste
    timeout: 120       # Timeout in Sekunden
```

### Konfigurationsoptionen:

- **path**: Absoluter Pfad zum Script
- **interval**: Wie oft das Script ausgeführt wird (in Sekunden)
- **args**: Liste von Argumenten die ans Script übergeben werden
- **timeout**: Maximale Laufzeit bevor das Script abgebrochen wird

## 3. Script Berechtigungen setzen

```bash
sudo chmod +x /opt/python_scripts/my_new_script.py
sudo chown monitoring:monitoring /opt/python_scripts/my_new_script.py
```

## 4. Daemon neu starten

Nach dem Hinzufügen eines Scripts muss der Daemon neu gestartet werden:

```bash
# Service neu starten
sudo systemctl restart edge-monitoring.service

# Status prüfen
sudo systemctl status edge-monitoring.service

# Logs anzeigen
sudo journalctl -u edge-monitoring.service -f
```

## 5. Script testen

### Manueller Test des Scripts:
```bash
# Script direkt testen
sudo python3 /opt/python_scripts/my_new_script.py

# Mit Daemon im Test-Modus
sudo python3 /opt/monitoring/edge_daemon.py --test-mode
```

### Status überprüfen:
```bash
# Daemon Status anzeigen
python3 /opt/monitoring/status_daemon.py

# Oder Live-Logs
sudo journalctl -u edge-monitoring.service -f
```

## Beispiel: iLO Monitoring hinzufügen

```yaml
scripts:
  ipmi:
    path: "/opt/python_scripts/get_ipmi_data.py"
    interval: 300
    args: ["--all"]
    timeout: 120
    
  # NEU: iLO Temperature Monitoring
  ilo_temps:
    path: "/opt/python_scripts/get_ilo_temps.py"
    interval: 300
    args: []
    timeout: 180
```

## Troubleshooting

### Script wird nicht ausgeführt:
1. Prüfe ob der Pfad korrekt ist
2. Prüfe die Berechtigungen (`ls -la /opt/python_scripts/`)
3. Prüfe die Logs: `sudo journalctl -u edge-monitoring.service -n 50`

### Script läuft in Timeout:
- Erhöhe den `timeout` Wert in der config.yaml
- Optimiere dein Script für bessere Performance

### Script Fehler:
- Teste das Script manuell: `sudo python3 /opt/python_scripts/script.py`
- Prüfe die Python-Dependencies
- Schaue in die Daemon-Logs für Fehlermeldungen

## Script-Vorlage

```python
#!/usr/bin/env python3
import os
import json
import socket
from datetime import datetime, timezone

# Konfiguration
EDGE_HOST = os.getenv("EDGE_HOST", "192.168.168.161")
EDGE_PORT = int(os.getenv("EDGE_PORT", "10530"))

def send_to_logstash(data):
    """Sendet Daten an Logstash"""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.connect((EDGE_HOST, EDGE_PORT))
            sock.sendall(json.dumps(data).encode('utf-8') + b'\n')
        return True
    except Exception as e:
        print(f"Error sending to Logstash: {e}")
        return False

def main():
    # Deine Monitoring-Logik hier
    data = {
        "@timestamp": datetime.now(timezone.utc).isoformat(),
        "host": socket.gethostname(),
        "service": "my_service",
        "metric": "my_metric",
        "value": 42
    }
    
    if send_to_logstash(data):
        print("✅ Data sent successfully")
        return 0
    else:
        print("❌ Failed to send data")
        return 1

if __name__ == "__main__":
    exit(main())
```

