#!/usr/bin/env python3
"""
Status-Script für Edge Monitoring Daemon
Zeigt aktuellen Status an
"""

import subprocess
import json
from datetime import datetime

def get_daemon_status():
    """Holt den Status des Daemons"""
    try:
        # Service-Status prüfen
        result = subprocess.run(['systemctl', 'is-active', 'edge-monitoring.service'], 
                              capture_output=True, text=True)
        service_status = result.stdout.strip()
        
        # Log-Datei lesen (letzte 20 Zeilen)
        try:
            log_result = subprocess.run(['tail', '-20', '/var/log/edge-monitoring.log'], 
                                      capture_output=True, text=True)
            log_lines = log_result.stdout.strip().split('\n')
        except:
            log_lines = ["Log file not accessible"]
        
        return service_status, log_lines
    except Exception as e:
        return "error", [f"Error: {e}"]

def print_status():
    """Zeigt den Status an"""
    print("\n" + "="*60)
    print("📊 EDGE MONITORING DAEMON STATUS")
    print("="*60)
    
    service_status, log_lines = get_daemon_status()
    
    # Service-Status
    if service_status == "active":
        print("🟢 Service Status: ACTIVE")
    elif service_status == "inactive":
        print("🔴 Service Status: INACTIVE")
    elif service_status == "failed":
        print("❌ Service Status: FAILED")
    else:
        print(f"⚠️  Service Status: {service_status.upper()}")
    
    print(f"📅 Checked: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()
    
    # Script-Status aus Logs analysieren
    print("📋 Script Status (from logs):")
    print("-" * 40)
    
    # IPMI Script Status analysieren
    ipmi_runs = [line for line in log_lines if "ipmi" in line.lower()]
    if ipmi_runs:
        print("🔄 IPMI Script:")
        print(f"   Total runs in log: {len(ipmi_runs)}")
        
        # Letzte erfolgreiche Ausführung
        last_success = [line for line in ipmi_runs if "completed successfully" in line]
        if last_success:
            print(f"   Last success: {last_success[-1].split(' - ')[0]}")
        
        # Letzte Ausführung
        last_run = [line for line in ipmi_runs if "Starting ipmi" in line]
        if last_run:
            print(f"   Last start: {last_run[-1].split(' - ')[0]}")
        
        # Aktuell laufend?
        running = [line for line in ipmi_runs if "Starting ipmi" in line and "completed successfully" not in line]
        if running and len(running) > len([line for line in ipmi_runs if "completed successfully" in line]):
            print("   Status: 🔄 RUNNING")
        else:
            print("   Status: ⏸️  IDLE")
    else:
        print("🔄 IPMI Script: No runs found in logs")
    
    print()
    
    # Log-Ausgabe
    print("📋 Recent Log Entries:")
    print("-" * 40)
    for line in log_lines[-10:]:  # Letzte 10 Zeilen
        if line.strip():
            print(f"   {line}")
    
    print("\n" + "="*60)
    print("💡 Tipp: Für detaillierten Status siehe /var/log/edge-monitoring.log")
    print("💡 Oder: journalctl -u edge-monitoring.service -f")
    print("💡 Oder: journalctl -u edge-monitoring.service --since '5 minutes ago'")

if __name__ == "__main__":
    print_status()
