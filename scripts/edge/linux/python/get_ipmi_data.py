#!/usr/bin/env python3
"""
IPMI Data Collector für Edge-Monitoring
Sammelt Fan-, Temperatur- und Power-Daten via IPMI und sendet sie an Logstash
"""

import os
import json
import socket
import argparse
import subprocess
import sys
import shlex
from datetime import datetime, timezone
from typing import Dict, List, Optional, Any

# ---- Konfiguration ----
EDGE_HOST = os.getenv("EDGE_HOST", "192.168.168.161")
EDGE_PORT = int(os.getenv("EDGE_PORT", "10550"))
HOSTS_FILE = os.getenv("IPMI_HOSTS_FILE", "/etc/ipmi/hosts.json")
TIMEOUT = float(os.getenv("IPMI_TIMEOUT", "30.0"))
IPMI_COMMAND = os.getenv("IPMI_COMMAND", "ipmitool")

def run_ipmi_command(host: str, username: str, password: str, command: str, debug: bool = False) -> Optional[str]:
    """Führt IPMI-Kommando aus - KORREKT mit Liste"""
    try:
        # IPMI-Kommando als Liste (sicher und korrekt)
        cmd = [
            IPMI_COMMAND,
            "-I", "lanplus",
            "-H", host,
            "-U", username,
            "-P", password
        ]
        
        # Kommando-Parameter hinzufügen - "power supply" als einzelnes Argument
        if command == 'sdr type "power supply"':
            cmd.extend(['sdr', 'type', 'power supply'])
        else:
            cmd.extend(command.split())
        
        if debug:
            print(f"[DEBUG] Führe aus: {cmd}")
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            check=True
        )
        
        if debug:
            print(f"[DEBUG] Output erhalten: {len(result.stdout)} Zeichen")
            if result.stdout:
                print(f"[DEBUG] Erste 900 Zeichen: {result.stdout[:900]}")
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        print(f"[!] IPMI-Timeout für {host}")
        return None
    except subprocess.CalledProcessError as e:
        print(f"[!] IPMI-Fehler für {host}: {e.stderr}")
        return None
    except Exception as e:
        print(f"[!] Fehler für {host}: {e}")
        return None

def parse_temperature_data(output: str) -> List[Dict[str, Any]]:
    """Parst Temperatur-Daten"""
    temps = []
    if not output:
        return temps
    
    for line in output.split('\n'):
        if '|' not in line:
            continue
            
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 5:
            continue
            
        sensor_name = parts[0]
        status = parts[2]
        reading = parts[4]
        
        if 'degrees C' in reading:
            try:
                temp_value = float(reading.replace(' degrees C', ''))
                temps.append({
                    'name': sensor_name,
                    'value': temp_value,
                    'status': status,
                    'unit': 'celsius'
                })
            except ValueError:
                continue
    
    return temps

def parse_fan_data(output: str) -> List[Dict[str, Any]]:
    """Parst Fan-Daten"""
    fans = []
    if not output:
        return fans
    
    for line in output.split('\n'):
        if '|' not in line:
            continue
            
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 5:
            continue
            
        sensor_name = parts[0]
        status = parts[2]
        reading = parts[4]
        
        if 'percent' in reading:
            try:
                duty_value = float(reading.replace(' percent', ''))
                fans.append({
                    'name': sensor_name,
                    'value': duty_value,
                    'status': status,
                    'unit': 'percent'
                })
            except ValueError:
                continue
    
    return fans

def parse_power_data(output: str, debug: bool = False) -> List[Dict[str, Any]]:
    """Parst Power-Daten aus sdr type power supply"""
    power_data = []
    if not output:
        return power_data
    
    if debug:
        print(f"[DEBUG] Parse Power Data - Input: {len(output)} Zeichen")
        print(f"[DEBUG] Erste 200 Zeichen: {output[:200]}")
    
    for line in output.split('\n'):
        if '|' not in line:
            continue
            
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 5:
            continue
            
        # Korrekte Spalten-Aufteilung:
        # Spalte 0: Sensor Name (Power Supply 1)
        # Spalte 1: Laufzeit in Stunden (41h) 
        # Spalte 2: Status (ok)
        # Spalte 3: Wert 10.1 (unbekannte Bedeutung)
        # Spalte 4: Watts + Presence (60 Watts, Presence detected)
        sensor_name = parts[0]      # Power Supply 1
        runtime_hours = parts[1]    # 41h (Laufzeit in Stunden)
        status = parts[2]           # ok
        value_unknown = parts[3]    # 10.1 (unbekannte Bedeutung)
        reading = parts[4]          # 60 Watts, Presence detected
        
        if debug:
            print(f"[DEBUG] Sensor: '{sensor_name}' | Runtime: '{runtime_hours}' | Status: '{status}' | Value: '{value_unknown}' | Reading: '{reading}'")
        
        # Nur Power-Sensoren verarbeiten (PS, Power Supply, Power Supplies)
        has_power_keyword = any(keyword in sensor_name.lower() for keyword in ['ps ', 'power supply', 'power supplies'])
        has_watts = 'watts' in reading.lower()
        has_presence = 'presence' in reading.lower()
        has_redundant = 'redundant' in reading.lower()
        
        if debug:
            print(f"[DEBUG] Has power keyword: {has_power_keyword}, Has watts: {has_watts}, Has presence: {has_presence}, Has redundant: {has_redundant}")
        
        if has_power_keyword and (has_watts or has_presence or has_redundant):
            sensor_data = {
                'name': sensor_name,
                'runtime_hours': runtime_hours,    # 41h, 42h, etc.
                'status': status,
                'value_unknown': value_unknown,    # 10.1, 10.2, etc. (unbekannte Bedeutung)
                'raw_reading': reading
            }
            
            # Watt-Werte extrahieren
            if has_watts:
                try:
                    power_value = float(reading.replace(' Watts', '').split(',')[0])
                    sensor_data['value'] = power_value
                    sensor_data['unit'] = 'watts'
                except ValueError:
                    pass
            
            # Presence-Status extrahieren
            if has_presence:
                if 'presence detected' in reading.lower():
                    sensor_data['presence'] = 'detected'
                elif 'device present' in reading.lower():
                    sensor_data['presence'] = 'present'
                else:
                    sensor_data['presence'] = 'unknown'
            
            # Redundancy-Status extrahieren
            if has_redundant:
                if 'fully redundant' in reading.lower():
                    sensor_data['redundancy'] = 'fully_redundant'
                else:
                    sensor_data['redundancy'] = reading.lower()
            
            power_data.append(sensor_data)
            
            if debug:
                print(f"[DEBUG] ✓ Power sensor gefunden: {sensor_name} = {sensor_data}")
    
    if debug:
        print(f"[DEBUG] Gefundene Power-Sensoren: {len(power_data)}")
    
    return power_data

def print_json(doc: dict):
    """Gibt JSON auf Konsole aus"""
    print("=" * 80)
    print("JSON OUTPUT:")
    print("=" * 80)
    print(json.dumps(doc, indent=2, ensure_ascii=False))
    print("=" * 80)

def send_json(doc: dict):
    """Sendet JSON an Logstash"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5.0)
        sock.connect((EDGE_HOST, EDGE_PORT))
        
        line = json.dumps(doc, ensure_ascii=False) + "\n"
        sock.sendall(line.encode("utf-8"))
        sock.close()
    except Exception as e:
        print(f"[!] Fehler beim Senden an Logstash: {e}")

def create_error_document(host: str, host_name: str, data_type: str, error_msg: str) -> Dict[str, Any]:
    """Erstellt ECS-konformes Error-Dokument"""
    return {
        "@timestamp": datetime.now(timezone.utc).isoformat(),
        "event": {
            "kind": "event",
            "category": ["hardware"],
            "type": ["error"],
            "outcome": "failure",
            "dataset": f"ipmi.{data_type}"
        },
        "service": {"type": "ipmi"},
        "host": {"name": host_name, "ip": [host]},
        "observer": {
            "vendor": "Generic",
            "product": "IPMI"
        },
        "error": {
            "message": error_msg
        }
    }

def create_metric_document(host: str, host_name: str, 
                          data_type: str, sensor: Dict[str, Any]) -> Dict[str, Any]:
    """Erstellt ECS-konformes JSON-Dokument für einen einzelnen Sensor"""
    doc = {
        "@timestamp": datetime.now(timezone.utc).isoformat(),
        "event": {
            "kind": "metric",
            "category": ["hardware"],
            "type": ["info"],
            "outcome": "success",
            "dataset": f"ipmi.{data_type}"
        },
        "service": {"type": "ipmi"},
        "host": {"name": host_name, "ip": [host]},
        "observer": {
            "vendor": "Generic",
            "product": "IPMI"
        },
        "ipmi": {
            "sensor": {
                "name": sensor.get("name"),
                "status": sensor.get("status"),
                "runtime_hours": sensor.get("runtime_hours"),
                "value_unknown": sensor.get("value_unknown"),
                "raw_reading": sensor.get("raw_reading")
            }
        }
    }
    
    # Metriken hinzufügen basierend auf Datentyp
    if data_type == "temp" and "value" in sensor:
        doc["metrics"] = {
            "temperature": {
                "celsius": sensor["value"]
            }
        }
    elif data_type == "fan" and "value" in sensor:
        doc["metrics"] = {
            "fan": {
                "rpm": sensor["value"]
            }
        }
    elif data_type == "power" and "value" in sensor:
        doc["metrics"] = {
            "power": {
                "watts": sensor["value"]
            }
        }
    
    # Zusätzliche Sensor-Informationen
    if "presence" in sensor:
        doc["ipmi"]["sensor"]["presence"] = sensor["presence"]
    if "redundancy" in sensor:
        doc["ipmi"]["sensor"]["redundancy"] = sensor["redundancy"]
    if "unit" in sensor:
        doc["ipmi"]["sensor"]["unit"] = sensor["unit"]
    
    return doc

def main():
    parser = argparse.ArgumentParser(description='IPMI Data Collector')
    parser.add_argument('--temp', action='store_true', help='Temperatur-Daten')
    parser.add_argument('--fan', action='store_true', help='Fan-Daten')
    parser.add_argument('--power', action='store_true', help='Power-Daten')
    parser.add_argument('--all', action='store_true', help='Alle Daten')
    parser.add_argument('--console', action='store_true', help='Konsole ausgeben')
    parser.add_argument('--debug', action='store_true', help='Debug-Ausgabe aktivieren')
    
    args = parser.parse_args()
    
    # Datentypen bestimmen
    data_types = []
    if args.all:
        data_types = ['temp', 'fan', 'power']
    else:
        if args.temp:
            data_types.append('temp')
        if args.fan:
            data_types.append('fan')
        if args.power:
            data_types.append('power')
    
    if not data_types:
        print("[!] Keine Datentypen ausgewählt.")
        sys.exit(1)
    
    print(f"[*] Sammle IPMI-Daten: {', '.join(data_types)}")
    
    # Hosts aus hosts.json laden
    try:
        with open(HOSTS_FILE, 'r') as f:
            hosts_data = json.load(f)
        
        # Prüfen ob es ein Array oder ein Objekt mit "hosts" Key ist
        if isinstance(hosts_data, list):
            hosts = hosts_data
        elif isinstance(hosts_data, dict) and 'hosts' in hosts_data:
            hosts = hosts_data['hosts']
        else:
            print(f"[!] Unbekannte JSON-Struktur in {HOSTS_FILE}")
            sys.exit(1)
            
        print(f"[*] {len(hosts)} Hosts aus {HOSTS_FILE} geladen")
    except FileNotFoundError:
        print(f"[!] Hosts-Datei {HOSTS_FILE} nicht gefunden")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"[!] Fehler beim Parsen von {HOSTS_FILE}: {e}")
        sys.exit(1)
    
    command_map = {
        'temp': 'sdr type temperature',
        'fan': 'sdr type fan', 
        'power': 'sdr type "power supply"'
    }
    
    # Für jeden Host und jeden Datentyp
    for host_config in hosts:
        # Unterstütze sowohl "ip" als auch "host" Feld
        host = host_config.get('ip') or host_config.get('host')
        username = host_config['username']
        password = host_config['password']
        host_name = host_config['name']
        
        print(f"\n[*] Verarbeite Host: {host_name} ({host})")
        
        for data_type in data_types:
            print(f"\n[*] Sammle {data_type}-Daten von {host_name}...")
            
            output = run_ipmi_command(host, username, password, command_map[data_type], args.debug)
        
            if output is None:
                print(f"[!] Keine {data_type}-Daten erhalten")
                # Error-Dokument erstellen und senden
                error_doc = create_error_document(host, host_name, data_type, f"IPMI-Kommando fehlgeschlagen: {command_map[data_type]}")
                if args.console:
                    print_json(error_doc)
                else:
                    send_json(error_doc)
                continue
            
            # Daten parsen
            if data_type == 'temp':
                sensor_data = parse_temperature_data(output)
            elif data_type == 'fan':
                sensor_data = parse_fan_data(output)
            elif data_type == 'power':
                sensor_data = parse_power_data(output, args.debug)
            else:
                continue
                
            if not sensor_data:
                print(f"[!] Keine {data_type}-Sensoren gefunden")
                continue
                
            # Einzelne JSON-Dokumente für jeden Sensor erstellen
            for sensor in sensor_data:
                metric_doc = create_metric_document(host, host_name, data_type, sensor)
                if args.console:
                    print_json(metric_doc)
                else:
                    send_json(metric_doc)
                # Bessere Ausgabe basierend auf Sensor-Typ
                sensor_name = sensor.get('name', 'Unknown')
                if 'value' in sensor and sensor['value'] is not None:
                    print(f"[✓] {host_name}: {sensor_name} -> {sensor['value']} {sensor.get('unit', '')}")
                elif 'presence' in sensor:
                    print(f"[✓] {host_name}: {sensor_name} -> {sensor['presence']}")
                elif 'redundancy' in sensor:
                    print(f"[✓] {host_name}: {sensor_name} -> {sensor['redundancy']}")
                else:
                    print(f"[✓] {host_name}: {sensor_name} -> {sensor.get('status', 'N/A')}")
    
    print("\n[✓] IPMI-Datensammlung abgeschlossen")

if __name__ == "__main__":
    main()