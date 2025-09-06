#!/usr/bin/env bash
set -euo pipefail; shopt -s lastpipe
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
source "$HERE/lib_utils.sh"; source "$HERE/lib_es.sh"

usage(){ cat <<USAGE
Usage: $0 [options]

Repariert rollover_alias für alle Indizes, die ILM-Policies haben aber keinen rollover_alias.

Options:
  --dry-run    Nur anzeigen, was repariert würde
  --force      Alle Indizes reparieren, auch wenn sie bereits rollover_alias haben
  --help       Diese Hilfe anzeigen

Beispiele:
  $0                    # Normale Reparatur
  $0 --dry-run          # Nur anzeigen, was passieren würde
  $0 --force            # Alle ILM-Indizes reparieren
USAGE
}

DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --help) usage; exit 0 ;;
    *) fail "Unbekannte Option: $1" ;;
  esac
done

# Services mit ILM-Policies
declare -A ILM_SERVICES=(
  ["veeam.syslog"]="logs-*-veeam-syslog-*"
  ["veeam.metrics"]="metrics-*-veeam-jobs-*" 
  ["ilo.metrics"]="metrics-*-ilo-*"
  ["ipmi.metrics"]="metrics-*-ipmi-*"
)

info "Suche nach Indizes ohne rollover_alias..."

total_repaired=0
total_checked=0

for service in "${!ILM_SERVICES[@]}"; do
  pattern="${ILM_SERVICES[$service]}"
  info "Prüfe Service: $service (Pattern: $pattern)"
  
  # Alle Indizes für diesen Service finden
  indices=$(es_get "/_cat/indices/$pattern?format=json" | jq -r '.[].index' 2>/dev/null || true)
  
  if [[ -z "$indices" ]]; then
    info "Keine Indizes gefunden für Pattern: $pattern"
    continue
  fi
  
  for index in $indices; do
    total_checked=$((total_checked + 1))
    
    # Prüfe ob Index ILM-Policy hat - hole alle Settings und suche nach ILM
    settings=$(es_get "/$index/_settings" 2>/dev/null || echo "{}")
    ilm_policy=$(echo "$settings" | jq -r '.[].settings.index.lifecycle.name // empty' 2>/dev/null || true)
    
    # Debug: Zeige was gefunden wurde
    info "Index $index: ILM-Policy='$ilm_policy'"
    
    if [[ -z "$ilm_policy" || "$ilm_policy" == "null" ]]; then
      info "Index $index hat keine ILM-Policy - überspringe"
      continue
    fi
    
    # Prüfe ob rollover_alias bereits gesetzt ist (nicht leer)
    rollover_alias=$(echo "$settings" | jq -r '.[].settings.index.lifecycle.rollover_alias // empty' 2>/dev/null || true)
    
    if [[ -n "$rollover_alias" && "$rollover_alias" != "null" && "$rollover_alias" != "" && "$FORCE" != "true" ]]; then
      info "Index $index hat bereits rollover_alias: $rollover_alias"
      continue
    fi
    
    # Finde den passenden Alias für diesen Index
    # Extrahiere Kunde und Service aus dem Index-Namen
    if [[ "$index" =~ ^(logs|metrics)-([^-]+)-(veeam-syslog|veeam-jobs|ilo|ipmi)-([0-9]+)$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      kunde="${BASH_REMATCH[2]}"
      service_part="${BASH_REMATCH[3]}"
      
      # Baue Alias-Namen
      case "$service_part" in
        "veeam-syslog") alias="logs-$kunde-veeam-syslog-write" ;;
        "veeam-jobs") alias="metrics-$kunde-veeam-jobs-write" ;;
        "ilo") alias="metrics-$kunde-ilo-write" ;;
        "ipmi") alias="metrics-$kunde-ipmi-write" ;;
        *) warn "Unbekannter Service-Teil: $service_part"; continue ;;
      esac
      
      # Prüfe ob Alias existiert
      if ! alias_exists "$alias"; then
        warn "Alias $alias existiert nicht für Index $index - überspringe"
        continue
      fi
      
      info "Repariere Index: $index -> Alias: $alias"
      
      if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY-RUN: Würde setzen: $index -> rollover_alias: $alias"
      else
        # Setze rollover_alias
        if es_put "/$index/_settings" "$(jq -nc --arg a "$alias" \
           '{index:{lifecycle:{rollover_alias:$a}}}')" >/dev/null; then
          ok "rollover_alias gesetzt: $index -> $alias"
          total_repaired=$((total_repaired + 1))
        else
          fail "Fehler beim Setzen von rollover_alias für $index"
        fi
      fi
    else
      warn "Index $index passt nicht zum erwarteten Pattern - überspringe"
    fi
  done
done

info "Zusammenfassung:"
info "  Geprüfte Indizes: $total_checked"
info "  Reparierte Indizes: $total_repaired"

if [[ "$DRY_RUN" == "true" ]]; then
  info "DRY-RUN abgeschlossen - keine Änderungen vorgenommen"
  info "Führe das Script ohne --dry-run aus, um die Reparaturen durchzuführen"
else
  if [[ $total_repaired -eq 0 ]]; then
    ok "Alle Indizes sind bereits korrekt konfiguriert!"
  else
    ok "Reparatur abgeschlossen: $total_repaired Indizes repariert"
  fi
fi
