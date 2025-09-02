#!/usr/bin/env bash
set -euo pipefail; shopt -s lastpipe
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
source "$HERE/lib_utils.sh"; source "$HERE/lib_es.sh"; source "$HERE/lib_render.sh"
need jq; command -v yq >/dev/null || warn "yq not found – falling back to defaults"


usage(){ cat <<USAGE
Usage:
onb cluster:init
onb service:add <service>
onb tenant:add <kunde> [services...]
onb smoke <service> <kunde>
USAGE
}


cluster_init(){
  info "Starting cluster:init against $ES_HOST"
  es_ok || fail "ES not reachable (/_cluster/health)"

  # Component Templates (idempotent)
  for ct in ct-common-settings ct-ecs-common; do
    if ct_exists "$ct"; then ok "CT exists: $ct"
    else es_put "/_component_template/$ct" "$(cat "$ROOT/cluster/$ct.json")" >/dev/null; ok "CT created: $ct"
    fi
  done

  for f in "$ROOT/cluster/ilm"/*.json; do
    [[ -e "$f" ]] || continue
    # 1) Policy-Name: aus _meta.policy_name, sonst Dateiname
    local name base
    name=$(jq -r '._meta.policy_name // empty' "$f")
    if [[ -z "$name" ]]; then base=$(basename "$f" .json); name="${base#ilm-}"; fi

    # 2) Payload ohne _meta senden (ILM akzeptiert nur {policy:{...}})
    local body
    body=$(jq 'del(._meta)' "$f")

    info "ILM file: $(basename "$f")  -> policy: $name"
    if ilm_exists "$name"; then
      ok "ILM exists: $name"
    else
      es_put "/_ilm/policy/$name" "$body" >/dev/null || fail "ILM create failed for $name"
      ok "ILM created: $name"
    fi
  done

}


service_add(){
  local svc="${1:?service}"
  local SVC_DIR="$ROOT/services/$svc"; [[ -d "$SVC_DIR" ]] || fail "unknown service: $svc"

  # 0) Namen der CTs aus module.yml ableiten
  local ct_map="ct-${svc//./-}-mapping"
  local ct_settings="" pattern="" policy="" comps="" priority=""

  if command -v yq >/dev/null; then
    ct_settings="$(yq -r '.settings_component // ""' "$SVC_DIR/module.yml" 2>/dev/null || true)"
    pattern="$(yq -r '.index_pattern' "$SVC_DIR/module.yml" 2>/dev/null || true)"
    policy="$(yq -r '.ilm_policy'    "$SVC_DIR/module.yml" 2>/dev/null || true)"
    comps="$(yq -r '.components | join(",")' "$SVC_DIR/module.yml" 2>/dev/null || true)"
    priority="$(yq -r '.priority' "$SVC_DIR/module.yml" 2>/dev/null || true)"
  fi
  [[ -n "$ct_settings" ]] || ct_settings="ct-${svc//./-}-settings-v1"  # Fallback
  [[ -n "$pattern"  ]] || pattern=$(grep -E '^index_pattern:' "$SVC_DIR/module.yml" | sed -E 's/^[^:]+:[[:space:]]*"?([^"]+)"?/\1/')
  [[ -n "$policy"   ]] || policy=$(grep -E '^ilm_policy:'    "$SVC_DIR/module.yml" | sed -E 's/^[^:]+:[[:space:]]*"?([^"]+)"?/\1/')
  [[ -n "$priority" ]] || priority=200
  [[ -n "$comps"    ]] || comps="ct-common-settings,ct-ecs-common,$ct_map,$ct_settings"

  info "module.yml → pattern=$pattern policy=$policy settings_ct=$ct_settings comps=$comps priority=$priority"

  # 1) Settings-CT aus Datei erstellen (falls nicht vorhanden)
  if ct_exists "$ct_settings"; then
    ok "CT exists: $ct_settings"
  else
    local settings_file="$SVC_DIR/settings_component.json"
    [[ -f "$settings_file" ]] || fail "missing settings_component.json for $svc"
    es_put "/_component_template/$ct_settings" "$(cat "$settings_file")" >/dev/null \
      || fail "create CT failed: $ct_settings"
    ok "CT created: $ct_settings"
  fi

  # 2) Mapping-CT erstellen/prüfen
  if ct_exists "$ct_map"; then
    ok "CT exists: $ct_map"
  else
    es_put "/_component_template/$ct_map" "$(cat "$SVC_DIR/component_template.json")" >/dev/null \
      || fail "create CT failed: $ct_map"
    ok "CT created: $ct_map"
  fi

  # 3) Index-Template rendern & anlegen (nutzt <policy> Platzhalter)
  local it_name="it-${svc//./-}"
  local it_body; it_body=$(render_file "$SVC_DIR/index_template.json" kunde='*' policy="$policy")

  if it_exists "$it_name"; then
    ok "IT exists: $it_name"
  else
    es_put "/_index_template/$it_name" "$it_body" >/dev/null \
      || fail "create IT failed: $it_name (prüfe: Policy/CT-Namen, composed_of)"
    ok "IT created: $it_name"
  fi
}





tenant_add(){
  local kunde="${1:?kunde}"; shift || true
  local ROOT_DIR="$ROOT"
  local cust_file="$ROOT_DIR/customers/${kunde^^}.yml"  # z.B. AGRARWARE.yml
  local services=()

  # 1) Services bestimmen: CLI-Args > Kunden-Manifest
  if [[ $# -gt 0 ]]; then
    services=("$@")
  else
    if [[ -f "$cust_file" ]]; then
      if command -v yq >/dev/null; then
        mapfile -t services < <(yq -r '.services[]' "$cust_file" 2>/dev/null || true)
      fi
      # Fallback, falls yq scheitert
      if [[ ${#services[@]} -eq 0 ]]; then
        services=( $(grep -E '^[[:space:]]*-[[:space:]]' "$cust_file" | sed -E 's/^[[:space:]]*-[[:space:]]*//') )
      fi
    else
      fail "open $cust_file: no such file (oder Services per CLI angeben)"
    fi
  fi
  [[ ${#services[@]} -gt 0 ]] || fail "keine Services gefunden"

  info "tenant=$kunde services=${services[*]}"

  # 2) Pro Service: write-alias und Bootstrap-Index anlegen
  for svc in "${services[@]}"; do
    local SVC_DIR="$ROOT_DIR/services/$svc"
    [[ -d "$SVC_DIR" ]] || fail "unknown service: $svc (Ordner fehlt: $SVC_DIR)"

    # module.yml lesen (write_alias, index_pattern; yq mit Fallback)
    local write_alias="" index_pattern=""
    if command -v yq >/dev/null; then
      write_alias="$(yq -r '.write_alias'   "$SVC_DIR/module.yml" 2>/dev/null || true)"
      index_pattern="$(yq -r '.index_pattern' "$SVC_DIR/module.yml" 2>/dev/null || true)"
    fi
    [[ -n "$write_alias" ]] || write_alias=$(grep -E '^write_alias:'   "$SVC_DIR/module.yml" | sed -E 's/^[^:]+:[[:space:]]*"?([^"]+)"?/\1/')
    [[ -n "$index_pattern" ]] || index_pattern=$(grep -E '^index_pattern:' "$SVC_DIR/module.yml" | sed -E 's/^[^:]+:[[:space:]]*"?([^"]+)"?/\1/')

    # Platzhalter ersetzen
    write_alias="${write_alias//<kunde>/$kunde}"
    index_pattern="${index_pattern//<kunde>/$kunde}"

    # Bootstrap-Index-Namen herleiten: <prefix>-000001 aus pattern & alias
    # Wir nehmen das übliche Schema deines Repos:
    # metrics-<kunde>-veeam-jobs-*  -> metrics-<kunde>-veeam-jobs-000001
    local prefix="${index_pattern%\*}"
    local bootstrap="${prefix}000001"

    info "svc=$svc alias=$write_alias bootstrap=$bootstrap"

        # Per-Tenant IT setzen (stellt rollover_alias per Template bereit)

    # 2a) Index-Template existiert?
    local it_name="it-${svc//./-}"
    if ! it_exists "$it_name"; then
      warn "Index Template fehlt: $it_name – führe service:add $svc zuerst aus"
      # Versuche es automatisch
      service_add "$svc"
    fi

    # 2b) Alias existiert?
    if alias_exists "$write_alias"; then
      ok "Alias exists: $write_alias"
    else
      # Erstelle Alias zusammen mit Bootstrap-Index in einem PUT (idempotent)
      # Erzeugt Index mit Alias, wenn weder Index noch Alias existieren.

#      es_put "/$bootstrap" "$(jq -nc --arg a "$write_alias" '{"aliases":{($a):{"is_write_index":true}}}')" >/dev/null || {

# neu: setze zusätzlich den rollover_alias als Index-Setting
es_put "/$bootstrap" "$(jq -nc \
  --arg a "$write_alias" \
  '{
     aliases:{($a):{is_write_index:true}},
     settings:{ index:{ lifecycle:{ rollover_alias:$a } } }
   }')" >/dev/null || {

        # Falls Index evtl. schon existiert: Alias separat setzen
        if index_exists "$bootstrap"; then
          es_put "/_aliases" "$(jq -nc --arg i "$bootstrap" --arg a "$write_alias" \
             '{actions:[{add:{index:$i, alias:$a, is_write_index:true}}]}')" >/dev/null \
             || fail "Alias add failed: $write_alias -> $bootstrap"
 	# **neu**: rollover_alias nachtragen, falls (noch) nicht gesetzt
  		es_put "/$bootstrap/_settings" "$(jq -nc --arg a "$write_alias" \
     		'{index:{lifecycle:{rollover_alias:$a}}}')" >/dev/null \
     		|| fail "Set rollover_alias failed on $bootstrap"
        else
          fail "Bootstrap create failed: $bootstrap"
        fi
      }
      ok "Bootstrap+Alias created: $bootstrap ⇢ $write_alias"
    fi

    # 2c) rollover_alias sicherstellen (auch wenn Alias schon existierte)
    #     -> ermittele den aktuellen Write-Index des Aliases
    {
      resolved="$(es_get "/_alias/$write_alias?filter_path=*")"
      write_index="$(echo "$resolved" \
        | jq -r 'to_entries[] | select(.value.aliases["'"$write_alias"'"].is_write_index==true) | .key' \
        2>/dev/null || true)"
      # Fallback: falls is_write_index-Flag fehlt (z.B. manuell angelegte Aliase),
      # nimm den einzigen gemappten Index
      if [[ -z "$write_index" ]]; then
        write_index="$(echo "$resolved" | jq -r 'keys[0]' 2>/dev/null || true)"
      fi

      if [[ -z "$write_index" ]]; then
        warn "Konnte Write-Index für $write_alias nicht auflösen – überspringe rollover_alias-Set."
      else
        # Prüfen ob bereits gesetzt
        settings="$(es_get "/$write_index/_settings?filter_path=*.*.settings.index.lifecycle.rollover_alias")"
        if ! echo "$settings" | grep -q "\"$write_alias\""; then
          info "Set rollover_alias on $write_index -> $write_alias"
          es_put "/$write_index/_settings" "$(jq -nc --arg a "$write_alias" \
             '{index:{lifecycle:{rollover_alias:$a}}}')" >/dev/null \
             || fail "rollover_alias set failed: $write_index"
          ok "rollover_alias updated on $write_index"
        fi
      fi
    }



  done
}


smoke(){
  local svc="${1:?svc}" kunde="${2:?kunde}"
  local alias
  case "$svc" in
    veeam.metrics) alias="metrics-$kunde-veeam-jobs-write" ;;
    veeam.syslog)  alias="logs-$kunde-veeam-syslog-write"  ;;
    *) fail "unknown service: $svc" ;;
  esac

  # 1) Ein Test-Doc schreiben (an den Alias)
  es_post "/$alias/_doc" "$(jq -nc \
      --arg ts "$(date -u +%FT%TZ)" \
      --arg k "$kunde" \
      --arg ds "$svc" \
      '{"@timestamp":$ts,
        "service":{"name":"veeam","type":"veeam"},
        "event":{"dataset":$ds,"category":"backup","kind":"event","type":"info","outcome":"success"},
        "labels":{"kunde":$k}}')" >/dev/null || fail "Smoke ingest failed"

  # 2) Write-Index auflösen
  # Methode A: _alias liefert komplettes Mapping mit is_write_index Flags
  local resolved
  resolved="$(es_get "/_alias/$alias?filter_path=*")"
  # Finde den Index, der is_write_index:true trägt
  local write_index
  write_index="$(echo "$resolved" | jq -r 'to_entries[] | select(.value.aliases["'"$alias"'"].is_write_index==true) | .key' 2>/dev/null || true)"

  [[ -n "$write_index" ]] || fail "Could not resolve write index for $alias"

  ok "Smoke: $alias -> $write_index"
}


case "${1:-}" in
cluster:init) cluster_init ;;
service:add) shift; service_add "$@" ;;
tenant:add) shift; tenant_add "$@" ;;
smoke) shift; smoke "$@" ;;
*) usage; exit 1 ;;
esac
