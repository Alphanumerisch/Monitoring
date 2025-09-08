#!/usr/bin/env python3
"""
Status-Script für Edge Monitoring Daemon
Zeigt aktuellen Status an
"""

import subprocess
import json
import os
from datetime import datetime

def get_daemon_status():
    """Holt den Status des Daemons"""
    try:
        # Service-Status prüfen
        result = subprocess.run(['systemctl', 'is-active', 'edge-monitoring.service'], 
                              capture_output=True, text=True)
        service_status = result.stdout.strip()
        
        # Log-Datei lesen (letzte 20 Zeilen) - versuche verschiedene Pfade
        log_lines = []
        log_paths = [
            '/var/log/edge-monitoring.log',  # Root-Pfad
            os.path.expanduser('~/edge-monitoring.log'),  # User-Home
            './edge-monitoring.log'  # Aktuelles Verzeichnis
        ]
        
        for log_path in log_paths:
            if os.path.exists(log_path):
                try:
                    log_result = subprocess.run(['tail', '-20', log_path], 
                                              capture_output=True, text=True)
                    log_lines = log_result.stdout.strip().split('\n')
                    print(f"📋 Log-Datei gefunden: {log_path}")
                    break
                except:
                    continue
        
        if not log_lines:
            log_lines = ["Keine Log-Datei gefunden oder nicht lesbar"]
        
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
    
    # Script-Status analysieren (generisch für alle Scripts)
    scripts_info = {}
    
    # Sammle alle Script-Starts und Completions
    for line in log_lines:
        if "🔄 Starting" in line:
            parts = line.split(" - ")
            if len(parts) >= 3:
                timestamp = parts[0]
                script_name = parts[2].replace("🔄 Starting ", "").replace("...", "").strip()
                if script_name not in scripts_info:
                    scripts_info[script_name] = {"starts": [], "completions": [], "cancellations": []}
                scripts_info[script_name]["starts"].append(timestamp)
        
        elif "✅" in line and "completed successfully" in line:
            parts = line.split(" - ")
            if len(parts) >= 3:
                timestamp = parts[0]
                # Extract script name from message like "✅ ipmi completed successfully in 66.9s"
                msg = parts[2]
                script_name = msg.replace("✅ ", "").split(" completed")[0].strip()
                if script_name not in scripts_info:
                    scripts_info[script_name] = {"starts": [], "completions": [], "cancellations": []}
                scripts_info[script_name]["completions"].append(timestamp)
                
        elif "⚠️" in line and "was cancelled" in line:
            parts = line.split(" - ")
            if len(parts) >= 3:
                timestamp = parts[0]
                msg = parts[2]
                script_name = msg.replace("⚠️ ", "").split(" was cancelled")[0].strip()
                if script_name not in scripts_info:
                    scripts_info[script_name] = {"starts": [], "completions": [], "cancellations": []}
                scripts_info[script_name]["cancellations"].append(timestamp)
    
    # Zeige Status für jedes gefundene Script
    for script_name, info in scripts_info.items():
        print(f"🔄 {script_name.upper()} Script:")
        
        total_starts = len(info["starts"])
        total_completions = len(info["completions"])
        total_cancellations = len(info["cancellations"])
        
        print(f"   Total starts: {total_starts}")
        print(f"   Successful runs: {total_completions}")
        print(f"   Cancelled runs: {total_cancellations}")
        
        # Letzter Start und Completion
        if info["starts"]:
            print(f"   Last start: {info['starts'][-1]}")
        if info["completions"]:
            print(f"   Last success: {info['completions'][-1]}")
            
        # Status bestimmen: Prüfe ob der letzte Start auch abgeschlossen wurde
        if info["starts"] and info["completions"]:
            last_start_time = info["starts"][-1]
            last_completion_time = info["completions"][-1] if info["completions"] else ""
            
            # Vergleiche Zeitstempel (als Strings)
            if last_start_time > last_completion_time:
                print("   Status: 🔄 RUNNING")
            else:
                print("   Status: ⏸️  IDLE")
        elif info["starts"] and not info["completions"]:
            print("   Status: 🔄 RUNNING (no completions yet)")
        else:
            print("   Status: ⏹️  UNKNOWN")
        
        print()
    
    if not scripts_info:
        print("📋 No script activity found in recent logs")
    
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
