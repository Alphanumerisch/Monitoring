#!/usr/bin/env python3
import os
import json
import socket
import yaml
import requests
from datetime import datetime, timezone
from requests.adapters import HTTPAdapter, Retry
from urllib3.exceptions import InsecureRequestWarning
requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)

# ---- Konfiguration (per ENV über dein Edge-Setup) ----
EDGE_HOST = os.getenv("EDGE_HOST", "192.168.168.161")
EDGE_PORT = int(os.getenv("EDGE_PORT", "10530"))
HOSTS_FILE = os.getenv("ILO_HOSTS_FILE", "/etc/ilo/hosts.yml")
TIMEOUT = float(os.getenv("ILO_TIMEOUT", "10.0"))

# ---- HTTP Session mit Retries aufbauen ----
session = requests.Session()
retries = Retry(total=2, backoff_factor=0.5, status_forcelist=[502, 503, 504])
session.mount("https://", HTTPAdapter(max_retries=retries))

# ---- Logstash TCP Socket vorbereiten ----
def open_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    s.connect((EDGE_HOST, EDGE_PORT))
    return s

def send_json(sock, doc: dict):
    line = json.dumps(doc, ensure_ascii=False) + "\n"
    sock.sendall(line.encode("utf-8"))

# ---- Hosts laden ----
with open(HOSTS_FILE, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}
ilos = cfg.get("ilos", [])
if not ilos:
    print("[!] Keine iLO-Hosts in hosts.yml gefunden.")
    raise SystemExit(1)

# ---- Socket öffnen (einmal) ----
try:
    sock = open_socket()
except Exception as e:
    print(f"[!] Konnte nicht zu Logstash verbinden: {e}")
    raise SystemExit(2)

# ---- Abfrage & Versand ----
for entry in ilos:
    ilo_host = entry["host"]
    ilo_name = entry.get("name", ilo_host)
    customer = entry.get("customer", "unknown")
    username = entry["username"]
    password = entry["password"]

    url = f"https://{ilo_host}/redfish/v1/Chassis/1/Thermal"
    try:
        resp = session.get(url, auth=(username, password), verify=False, timeout=TIMEOUT)
        resp.raise_for_status()
        data = resp.json()
    except requests.RequestException as e:
        # Fehlerereignis (ECS-konform als event.type=error)
        err_doc = {
            "@timestamp": datetime.now(timezone.utc).isoformat(),
            "event": {
                "kind": "event",
                "category": ["hardware"],
                "type": ["error"],
                "outcome": "failure",
                "dataset": "ilo.thermal"
            },
            "service": {"type": "ilo"},
            "host": {"name": ilo_name, "ip": [ilo_host]},
            "observer": {
                "vendor": "HPE",
                "product": "iLO"
            },
            "hpe": {"ilo": {"error": str(e)}}
        }
        try:
            send_json(sock, err_doc)
        except Exception as se:
            print(f"[!] Sende-Fehler (Error-Doc) an Logstash: {se}")
        continue

    for sensor in data.get("Temperatures", []):
        temp = sensor.get("ReadingCelsius")
        if temp in (None, 0):
            continue

        doc = {
            "@timestamp": datetime.now(timezone.utc).isoformat(),
            # minimale ECS:
            "event": {
                "kind": "metric",
                "category": ["hardware"],
                "type": ["info"],
                "outcome": "success",
                "dataset": "ilo.thermal"
            },
            "service": {"type": "ilo"},
            "host": {"name": ilo_name, "ip": [ilo_host]},
            "observer": {
                "vendor": "HPE",
                "product": "iLO"
            },

            # vendor-/domänenspezifisch unter Namespace:
            "hpe": {
                "ilo": {
                    "sensor": {
                        "id": sensor.get("SensorNumber"),
                        "name": sensor.get("Name"),
                        "context": sensor.get("PhysicalContext"),
                        "health": (sensor.get("Status") or {}).get("Health", "Unknown"),
                        "thresholds": {
                            "upper_critical": sensor.get("UpperThresholdCritical"),
                            "upper_fatal": sensor.get("UpperThresholdFatal"),
                            "warning_user": ((sensor.get("Oem") or {}).get("Hpe") or {}).get("WarningTempUserThreshold"),
                            "critical_user": ((sensor.get("Oem") or {}).get("Hpe") or {}).get("CriticalTempUserThreshold"),
                        }
                    }
                }
            },

            # messwert (naheliegendes Schema)
            "metrics": {
                "temperature": {
                    "celsius": temp
                }
            }
        }

        # None-Werte aus thresholds entfernen
        thresholds = doc["hpe"]["ilo"]["sensor"]["thresholds"]
        doc["hpe"]["ilo"]["sensor"]["thresholds"] = {k: v for k, v in thresholds.items() if v is not None}

        try:
            send_json(sock, doc)
            print(f"[✓] {ilo_name}: Sensor '{sensor.get('Name')}' -> {temp} °C gesendet")
        except Exception as e:
            print(f"[!] Sende-Fehler an Logstash: {e}")

# Socket schließen
try:
    sock.close()
except Exception:
    pass
