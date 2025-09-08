#!/usr/bin/env python3
"""
Edge Monitoring Daemon
Orchestriert die Ausführung von Monitoring-Scripts
"""

import asyncio
import subprocess
import yaml
from datetime import datetime, timedelta
import logging
import os
import json
import signal
import sys

class EdgeMonitoringDaemon:
    def __init__(self, config_file="/opt/monitoring/config.yaml"):
        self.check_permissions()  # Prüfe Berechtigungen zuerst
        self.config = self.load_config(config_file)
        self.setup_logging()
        self.running_scripts = {}  # Track running scripts
        self.script_stats = {}     # Track script statistics
        self.start_time = datetime.now()
    
    def check_permissions(self):
        """Prüft ob das Script mit ausreichenden Berechtigungen läuft"""
        self.is_root = os.geteuid() == 0
        
        if not self.is_root:
            print("\n" + "="*60)
            print("⚠️  WARNUNG: Dieses Script läuft ohne Root-Rechte!")
            print("="*60)
            print("\nFür den produktiven Einsatz wird empfohlen, das Script")
            print("mit Root-Rechten auszuführen:")
            print("\n  sudo python3 /opt/monitoring/edge_daemon.py")
            print("\nOder verwenden Sie den systemd Service:")
            print("  sudo systemctl start edge-monitoring.service")
            print("\nDas Script wird jetzt im eingeschränkten Modus fortfahren.")
            print("Logs werden im aktuellen Verzeichnis gespeichert.")
            print("="*60 + "\n")
            
            # Warte 3 Sekunden, damit der Benutzer die Warnung lesen kann
            import time
            time.sleep(3)
        
    def load_config(self, config_file):
        """Lädt Konfiguration aus YAML"""
        with open(config_file, 'r') as f:
            return yaml.safe_load(f)
    
    def setup_logging(self):
        """Konfiguriert Logging"""
        # Log-Datei abhängig von Berechtigungen
        if self.is_root:
            log_file = '/var/log/edge-monitoring.log'
        else:
            # Im User-Home-Verzeichnis oder aktuellem Verzeichnis
            log_file = os.path.expanduser('~/edge-monitoring.log')
            if not os.access(os.path.dirname(log_file), os.W_OK):
                log_file = './edge-monitoring.log'
            print(f"📝 Log-Datei: {log_file}")
        
        try:
            logging.basicConfig(
                level=logging.INFO,
                format='%(asctime)s - %(levelname)s - %(message)s',
                handlers=[
                    logging.FileHandler(log_file),
                    logging.StreamHandler()
                ]
            )
            self.logger = logging.getLogger(__name__)
        except PermissionError as e:
            # Fallback: Nur Console-Logging
            print(f"⚠️  Konnte Log-Datei nicht erstellen: {e}")
            print("   Verwende nur Console-Output.")
            logging.basicConfig(
                level=logging.INFO,
                format='%(asctime)s - %(levelname)s - %(message)s',
                handlers=[logging.StreamHandler()]
            )
            self.logger = logging.getLogger(__name__)
    
    def should_run_script(self, script_name, script_config):
        """Prüft ob Script ausgeführt werden soll"""
        if script_name in self.running_scripts:
            return False
        
        if 'last_run' not in script_config:
            return True
        
        now = datetime.now()
        time_since_last = (now - script_config['last_run']).total_seconds()
        return time_since_last >= script_config['interval']
    
    async def run_script(self, script_name, script_config):
        """Führt Script aus"""
        start_time = datetime.now()
        end_time = None
        duration = 0
        status = 'unknown'
        process = None
        
        # Script als laufend markieren
        self.running_scripts[script_name] = {
            'start_time': start_time,
            'status': 'running'
        }
        
        try:
            self.logger.info(f"🔄 Starting {script_name}...")
            
            # Script ausführen (sendet selbst an Logstash)
            process = await asyncio.create_subprocess_exec(
                'python3', script_config['path'], *script_config.get('args', []),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            
            stdout, stderr = await asyncio.wait_for(
                process.communicate(), 
                timeout=script_config.get('timeout', 300)
            )
            
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            
            if process.returncode == 0:
                self.logger.info(f"✅ {script_name} completed successfully in {duration:.1f}s")
                script_config['last_run'] = end_time
                status = 'success'
            else:
                self.logger.error(f"❌ {script_name} failed: {stderr.decode()}")
                status = 'failed'
                
        except asyncio.TimeoutError:
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            self.logger.error(f"⏰ {script_name} timed out after {duration:.1f}s")
            status = 'timeout'
            
            # Prozess bei Timeout beenden
            if process and process.returncode is None:
                try:
                    process.terminate()
                    await asyncio.wait_for(process.wait(), timeout=5.0)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()
                except Exception:
                    pass
        except asyncio.CancelledError:
            # Script wurde abgebrochen (z.B. durch Ctrl+C)
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            self.logger.warning(f"⚠️ {script_name} was cancelled after {duration:.1f}s")
            status = 'cancelled'
            
            # Versuche den Prozess sauber zu beenden
            if process and process.returncode is None:
                try:
                    process.terminate()
                    # Gib dem Prozess 5 Sekunden Zeit zum Beenden
                    await asyncio.wait_for(process.wait(), timeout=5.0)
                except asyncio.TimeoutError:
                    # Wenn er nicht beendet, kill ihn
                    process.kill()
                    await process.wait()
                except Exception:
                    pass  # Ignoriere Fehler beim Cleanup
            
            raise  # Re-raise um sauberes Herunterfahren zu ermöglichen
        except Exception as e:
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            self.logger.error(f"💥 {script_name} error: {e}")
            status = 'error'
        finally:
            # Stelle sicher, dass end_time gesetzt ist
            if end_time is None:
                end_time = datetime.now()
                duration = (end_time - start_time).total_seconds()
            # Script-Statistiken aktualisieren
            if script_name not in self.script_stats:
                self.script_stats[script_name] = {
                    'total_runs': 0,
                    'successful_runs': 0,
                    'failed_runs': 0,
                    'last_run': None,
                    'last_duration': None,
                    'last_status': None
                }
            
            self.script_stats[script_name]['total_runs'] += 1
            self.script_stats[script_name]['last_run'] = end_time
            self.script_stats[script_name]['last_duration'] = duration
            self.script_stats[script_name]['last_status'] = status
            
            if status == 'success':
                self.script_stats[script_name]['successful_runs'] += 1
            else:
                self.script_stats[script_name]['failed_runs'] += 1
            
            # Script als beendet markieren
            if script_name in self.running_scripts:
                del self.running_scripts[script_name]
    
    def print_status(self):
        """Zeigt aktuellen Status in der Konsole"""
        print("\n" + "="*60)
        print("🚀 EDGE MONITORING DAEMON STATUS")
        print("="*60)
        
        # Daemon-Status
        uptime = datetime.now() - self.start_time
        print(f"📊 Daemon Status: RUNNING")
        print(f"⏰ Uptime: {uptime}")
        print(f"📅 Started: {self.start_time.strftime('%Y-%m-%d %H:%M:%S')}")
        print()
        
        # Script-Status
        for script_name, script_config in self.config['scripts'].items():
            print(f"📋 Script: {script_name}")
            print(f"   Path: {script_config['path']}")
            print(f"   Interval: {script_config['interval']}s")
            print(f"   Timeout: {script_config.get('timeout', 300)}s")
            
            # Laufstatus
            if script_name in self.running_scripts:
                running = self.running_scripts[script_name]
                duration = (datetime.now() - running['start_time']).total_seconds()
                print(f"   Status: 🔄 RUNNING (since {duration:.1f}s)")
            else:
                print(f"   Status: ⏸️  IDLE")
            
            # Letzte Ausführung
            if script_config.get('last_run'):
                last_run = script_config['last_run']
                next_run = last_run + timedelta(seconds=script_config['interval'])
                print(f"   Last Run: {last_run.strftime('%Y-%m-%d %H:%M:%S')}")
                print(f"   Next Run: {next_run.strftime('%Y-%m-%d %H:%M:%S')}")
            else:
                print(f"   Last Run: Never")
                # Wenn Script gerade läuft, zeige wann es fertig sein sollte
                if script_name in self.running_scripts:
                    estimated_end = self.running_scripts[script_name]['start_time'] + timedelta(seconds=script_config['interval'])
                    print(f"   Next Run: ~{estimated_end.strftime('%Y-%m-%d %H:%M:%S')} (after current run)")
                else:
                    # Zeige sofort als nächste Ausführung
                    print(f"   Next Run: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} (immediately)")
            
            # Statistiken
            if script_name in self.script_stats:
                stats = self.script_stats[script_name]
                success_rate = (stats['successful_runs'] / stats['total_runs'] * 100) if stats['total_runs'] > 0 else 0
                print(f"   Total Runs: {stats['total_runs']}")
                print(f"   Success Rate: {success_rate:.1f}%")
                print(f"   Last Duration: {stats['last_duration']:.1f}s" if stats['last_duration'] else "   Last Duration: N/A")
                print(f"   Last Status: {stats['last_status']}")
            
            print()
        
        print("="*60)
    
    def setup_signal_handlers(self):
        """Setup für Signal-Handler"""
        self.shutdown_event = asyncio.Event()
        
        def signal_handler(signum, frame):
            print(f"\n🛑 Received signal {signum}, shutting down gracefully...")
            self.shutdown_event.set()
        
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
    
    async def status_loop(self):
        """Status-Loop für regelmäßige Anzeige"""
        # Sofort Status anzeigen beim Start
        self.print_status()
        
        while not self.shutdown_event.is_set():
            try:
                await asyncio.wait_for(self.shutdown_event.wait(), timeout=30)
                break  # Shutdown requested
            except asyncio.TimeoutError:
                # Timeout erreicht, Status anzeigen
                self.print_status()
    
    async def main_loop(self):
        """Hauptschleife"""
        self.logger.info("🚀 Edge Monitoring Daemon started")
        self.setup_signal_handlers()
        
        # Alle laufenden Tasks sammeln
        self.running_tasks = []
        
        try:
            # Status-Loop starten
            status_task = asyncio.create_task(self.status_loop())
            self.running_tasks.append(status_task)
            
            # Timer für jedes Script erstellen
            for script_name, script_config in self.config['scripts'].items():
                # Sofort ausführen beim Start
                task = asyncio.create_task(self.run_script(script_name, script_config))
                self.running_tasks.append(task)
                
                # Timer für regelmäßige Ausführung
                async def timer_loop(name=script_name, config=script_config):
                    while not self.shutdown_event.is_set():
                        try:
                            await asyncio.wait_for(
                                self.shutdown_event.wait(), 
                                timeout=config['interval']
                            )
                            break  # Shutdown requested
                        except asyncio.TimeoutError:
                            # Interval erreicht, Script ausführen
                            if not self.shutdown_event.is_set():
                                await self.run_script(name, config)
                
                timer_task = asyncio.create_task(timer_loop())
                self.running_tasks.append(timer_task)
            
            # Warte auf Shutdown
            await self.shutdown_event.wait()
            
            self.logger.info("🛑 Shutdown initiated, cancelling tasks...")
            
            # Alle Tasks abbrechen
            for task in self.running_tasks:
                if not task.done():
                    task.cancel()
            
            # Warte darauf, dass alle Tasks beendet sind
            await asyncio.gather(*self.running_tasks, return_exceptions=True)
            
            # Kleine Verzögerung für Subprocess-Cleanup
            await asyncio.sleep(0.1)
            
            self.logger.info("✅ All tasks cancelled, shutting down cleanly")
            self.print_status()
            
        except Exception as e:
            self.logger.error(f"💥 Error in main loop: {e}")
            raise

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Edge Monitoring Daemon')
    parser.add_argument('--test-mode', action='store_true', 
                       help='Startet im Test-Modus ohne Root-Rechte-Prüfung')
    parser.add_argument('--config', default='/opt/monitoring/config.yaml',
                       help='Pfad zur Konfigurationsdatei')
    args = parser.parse_args()
    
    # Wenn Test-Modus, überschreibe die Berechtigungsprüfung
    if args.test_mode:
        print("🧪 Test-Modus aktiviert - Root-Rechte-Prüfung wird übersprungen")
        EdgeMonitoringDaemon.check_permissions = lambda self: setattr(self, 'is_root', False)
    
    daemon = EdgeMonitoringDaemon(config_file=args.config)
    asyncio.run(daemon.main_loop())
