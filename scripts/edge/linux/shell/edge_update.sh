#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="/tmp/edge-setup/monitoring/logstash/edge/pipelines"
DEST_DIR="/etc/logstash/pipelines/forwarder"
BACKUP_DIR="/var/backups/logstash-pipelines"
mkdir -p "$BACKUP_DIR"

# Mapping: logischer Name -> Dateiname
declare -A MAP=(
  [veeam.metrics]="10-input-veeam-metrics.conf"
  [veeam.syslog]="11-input-veeam-syslog.conf"
  [ilo.metrics]="12-input-ilo-metrics.conf"
  [ilo.syslog]="13-input-ilo-syslog.conf"
  [winlogbeat.input]="14-input-winlogbeat.conf"
  [utm.syslog]="15-input-utm-syslog.conf"
  [filter.common]="90-filter-common.conf"
  [out.rz]="99-output-to-rz.conf"
)

usage() { echo "Usage: $0 pipe:update <name>   (Namen: ${!MAP[@]})"; }

cmd="${1:-}"; name="${2:-}"
[[ "$cmd" == "pipe:update" && -n "${name}" ]] || { usage; exit 1; }

src="$SRC_DIR/${MAP[$name]:-}"
dst="$DEST_DIR/${MAP[$name]:-}"
[[ -n "${MAP[$name]:-}" ]] || { echo "[ERR] Unbekannter Name: $name"; exit 1; }
[[ -f "$src" ]] || { echo "[ERR] Quelle fehlt: $src"; exit 1; }
[[ -f "$dst" ]] || { echo "[ERR] Ziel fehlt (erst installieren): $dst"; exit 1; }

if cmp -s "$src" "$dst"; then
  echo "[SKIP] Unverändert: $name"
  exit 0
fi

ts="$(date +%Y%m%d-%H%M%S)"
cp -a "$dst" "$BACKUP_DIR/$(basename "$dst").$ts.bak"
install -m 0640 -o root -g logstash "$src" "$dst"

echo "[*] Config-Test…"
if sudo -u logstash /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t; then
  systemctl reload logstash || systemctl restart logstash
  echo "[OK] Aktualisiert: $name"
else
  echo "[ERR] Config-Test fehlgeschlagen – Rollback."
  cp -a "$BACKUP_DIR/$(basename "$dst").$ts.bak" "$dst"
  exit 1
fi
