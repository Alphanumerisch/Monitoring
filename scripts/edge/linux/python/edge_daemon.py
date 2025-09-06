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
        self.config = self.load_config(config_file)
        self.setup_logging()
        self.running_scripts = {}  # Track running scripts
        self.script_stats = {}     # Track script statistics
        self.start_time = datetime.now()
        
    def load_config(self, config_file):
        """Lädt Konfiguration aus YAML"""
        with open(config_file, 'r') as f:
            return yaml.safe_load(f)
    
    def setup_logging(self):
        """Konfiguriert Logging"""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler('/var/log/edge-monitoring.log'),
                logging.StreamHandler()
            ]
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
        except Exception as e:
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            self.logger.error(f"💥 {script_name} error: {e}")
            status = 'error'
        finally:
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
                print(f"   Next Run: Unknown")
            
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
        def signal_handler(signum, frame):
            print(f"\n🛑 Received signal {signum}, shutting down...")
            self.print_status()
            sys.exit(0)
        
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
    
    async def status_loop(self):
        """Status-Loop für regelmäßige Anzeige"""
        # Sofort Status anzeigen beim Start
        self.print_status()
        
        while True:
            await asyncio.sleep(30)  # Alle 30 Sekunden Status anzeigen
            self.print_status()
    
    async def main_loop(self):
        """Hauptschleife"""
        self.logger.info("🚀 Edge Monitoring Daemon started")
        self.setup_signal_handlers()
        
        # Status-Loop starten
        status_task = asyncio.create_task(self.status_loop())
        
        # Timer für jedes Script erstellen
        tasks = []
        for script_name, script_config in self.config['scripts'].items():
            # Sofort ausführen beim Start
            asyncio.create_task(self.run_script(script_name, script_config))
            
            # Timer für regelmäßige Ausführung
            async def timer_loop(name, config):
                while True:
                    await asyncio.sleep(config['interval'])
                    await self.run_script(name, config)
            
            tasks.append(asyncio.create_task(timer_loop(script_name, script_config)))
        
        # Alle Timer parallel laufen lassen
        all_tasks = [status_task] + tasks
        await asyncio.gather(*all_tasks)

if __name__ == "__main__":
    daemon = EdgeMonitoringDaemon()
    asyncio.run(daemon.main_loop())
